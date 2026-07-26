// Context-aware probe of the FTS5 tokenizer that ships inside our SQLCipher pod.
//
// Compiled and driven by scripts/generate-search-unicode-tables.py. It links the *bundled*
// amalgamation rather than the system sqlite3, so the emitted tables describe the engine that will
// actually run on device.
//
// Every scalar is probed in context, as "a<scalar>b", because probing a scalar alone cannot
// separate the two ways of producing no token:
//
//   a<s>b -> "ab"          s is IGNORED  (a diacritic removed in place; the token continues)
//   a<s>b -> "a", "b"      s is SEPARATOR
//   a<s>b -> one other term s is TOKEN, and its folded form is that term minus the a/b sentinels
//
// The distinction is load-bearing: treating U+0301 as a separator splits "e<0301>galite<0301>" into
// two tokens where the engine produces one, so the normalizer and the index would disagree.
//
// Output is TSV on stdout: codepoint<TAB>class<TAB>foldedCodepointOrMinus

#include <stdio.h>
#include <string.h>
#include "sqlite3.h"

enum { CLASS_SEPARATOR = 0, CLASS_TOKEN = 1, CLASS_IGNORED = 2 };

static int utf8_encode(unsigned int cp, char *out) {
    if (cp < 0x80) { out[0] = (char)cp; return 1; }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

static unsigned int utf8_decode_single(const char *s, int len) {
    unsigned char c = (unsigned char)s[0];
    if (len == 1) return c;
    if (len == 2) return ((c & 0x1FU) << 6) | ((unsigned char)s[1] & 0x3FU);
    if (len == 3)
        return ((c & 0x0FU) << 12) | (((unsigned char)s[1] & 0x3FU) << 6) |
               ((unsigned char)s[2] & 0x3FU);
    return ((c & 0x07U) << 18) | (((unsigned char)s[1] & 0x3FU) << 12) |
           (((unsigned char)s[2] & 0x3FU) << 6) | ((unsigned char)s[3] & 0x3FU);
}

static void fail(sqlite3 *db, const char *what) {
    fprintf(stderr, "%s: %s\n", what, db ? sqlite3_errmsg(db) : "(no db)");
}

int main(int argc, char **argv) {
    const char *tokenize = argc > 1 ? argv[1] : "unicode61 remove_diacritics 2";

    sqlite3 *db = NULL;
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) { fail(db, "open"); return 1; }

    char ddl[512];
    snprintf(ddl, sizeof ddl,
             "CREATE VIRTUAL TABLE t USING fts5(x, tokenize='%s');"
             "CREATE VIRTUAL TABLE v USING fts5vocab(t, instance);",
             tokenize);
    if (sqlite3_exec(db, ddl, NULL, NULL, NULL) != SQLITE_OK) { fail(db, "create"); return 1; }

    sqlite3_stmt *insert = NULL, *select = NULL, *clear = NULL;
    sqlite3_prepare_v2(db, "INSERT INTO t(rowid,x) VALUES(?,?)", -1, &insert, NULL);
    sqlite3_prepare_v2(db, "SELECT doc, term FROM v ORDER BY doc, offset", -1, &select, NULL);
    sqlite3_prepare_v2(db, "DELETE FROM t", -1, &clear, NULL);
    if (!insert || !select || !clear) { fail(db, "prepare"); return 1; }

    // Batching keeps the index small enough that vocab scans stay cheap.
    const unsigned int BATCH = 4096;
    unsigned int cp = 0;
    while (cp <= 0x10FFFF) {
        unsigned int batch_start = cp, count = 0;
        sqlite3_exec(db, "BEGIN", NULL, NULL, NULL);
        while (cp <= 0x10FFFF && count < BATCH) {
            if (cp >= 0xD800 && cp <= 0xDFFF) { cp++; continue; }  // surrogates are not scalars
            char buf[16];
            int n = 0;
            buf[n++] = 'a';
            n += utf8_encode(cp, buf + n);
            buf[n++] = 'b';
            sqlite3_bind_int64(insert, 1, cp);
            sqlite3_bind_text(insert, 2, buf, n, SQLITE_TRANSIENT);
            if (sqlite3_step(insert) != SQLITE_DONE) { fail(db, "insert"); return 1; }
            sqlite3_reset(insert);
            cp++; count++;
        }
        sqlite3_exec(db, "COMMIT", NULL, NULL, NULL);

        // Collect terms per doc, in offset order.
        unsigned int current = 0xFFFFFFFFU;
        int terms = 0;
        char first[64];
        first[0] = 0;
        while (sqlite3_step(select) == SQLITE_ROW) {
            unsigned int doc = (unsigned int)sqlite3_column_int64(select, 0);
            const char *term = (const char *)sqlite3_column_text(select, 1);
            if (doc != current) {
                if (current != 0xFFFFFFFFU) {
                    // emit previous
                    if (terms >= 2) printf("%u\t%d\t-\n", current, CLASS_SEPARATOR);
                    else if (strcmp(first, "ab") == 0) printf("%u\t%d\t-\n", current, CLASS_IGNORED);
                    else {
                        int len = (int)strlen(first);
                        if (len >= 2 && first[0] == 'a' && first[len - 1] == 'b') {
                            unsigned int folded = utf8_decode_single(first + 1, len - 2);
                            printf("%u\t%d\t%u\n", current, CLASS_TOKEN, folded);
                        } else {
                            printf("%u\t%d\t-\n", current, CLASS_SEPARATOR);
                        }
                    }
                }
                current = doc;
                terms = 0;
                first[0] = 0;
            }
            if (terms == 0 && term) {
                strncpy(first, term, sizeof first - 1);
                first[sizeof first - 1] = 0;
            }
            terms++;
        }
        if (current != 0xFFFFFFFFU) {
            if (terms >= 2) printf("%u\t%d\t-\n", current, CLASS_SEPARATOR);
            else if (strcmp(first, "ab") == 0) printf("%u\t%d\t-\n", current, CLASS_IGNORED);
            else {
                int len = (int)strlen(first);
                if (len >= 2 && first[0] == 'a' && first[len - 1] == 'b') {
                    unsigned int folded = utf8_decode_single(first + 1, len - 2);
                    printf("%u\t%d\t%u\n", current, CLASS_TOKEN, folded);
                } else {
                    printf("%u\t%d\t-\n", current, CLASS_SEPARATOR);
                }
            }
        }
        sqlite3_reset(select);

        // Scalars that produced no vocab row at all are separators that swallowed both sentinels;
        // in practice every doc yields at least one term, but be explicit rather than silent.
        (void)batch_start;
        sqlite3_step(clear);
        sqlite3_reset(clear);
    }

    sqlite3_finalize(insert);
    sqlite3_finalize(select);
    sqlite3_finalize(clear);
    sqlite3_close(db);
    return 0;
}
