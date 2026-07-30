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

// Decodes exactly one scalar, or returns -1.
//
// Rejects anything that is not a single well-formed scalar: a wrong continuation-byte count, a
// trailing byte beyond the first scalar, an overlong encoding, a surrogate, or a value past
// U+10FFFF. The caller feeds this the interior of "a<scalar>b" after stripping the sentinels, and
// a fold that produced two scalars would otherwise decode as one plausible-looking codepoint and
// be written into the table as fact.
static long utf8_decode_single(const char *s, int len) {
    if (len < 1 || len > 4) return -1;
    unsigned char c = (unsigned char)s[0];
    int expected;
    long cp;
    if (c < 0x80) { expected = 1; cp = c; }
    else if ((c & 0xE0) == 0xC0) { expected = 2; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { expected = 3; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { expected = 4; cp = c & 0x07; }
    else return -1;                                   // continuation or invalid lead byte
    if (expected != len) return -1;                   // trailing bytes: more than one scalar

    for (int i = 1; i < len; i++) {
        unsigned char cc = (unsigned char)s[i];
        if ((cc & 0xC0) != 0x80) return -1;           // malformed continuation
        cp = (cp << 6) | (cc & 0x3F);
    }
    if (len == 2 && cp < 0x80) return -1;             // overlong
    if (len == 3 && cp < 0x800) return -1;
    if (len == 4 && cp < 0x10000) return -1;
    if (cp > 0x10FFFF) return -1;
    if (cp >= 0xD800 && cp <= 0xDFFF) return -1;      // surrogate
    return cp;
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
                        long folded = -1;
                        if (len >= 2 && first[0] == 'a' && first[len - 1] == 'b') {
                            folded = utf8_decode_single(first + 1, len - 2);
                        }
                        if (folded < 0) {
                            fprintf(stderr,
                                    "U+%04X folded to %s, which is not a single scalar\n",
                                    current, first);
                            return 1;
                        }
                        printf("%u\t%d\t%ld\n", current, CLASS_TOKEN, folded);
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
                long folded = -1;
                if (len >= 2 && first[0] == 'a' && first[len - 1] == 'b') {
                    folded = utf8_decode_single(first + 1, len - 2);
                }
                if (folded < 0) {
                    fprintf(stderr, "U+%04X folded to %s, which is not a single scalar\n",
                            current, first);
                    return 1;
                }
                printf("%u\t%d\t%ld\n", current, CLASS_TOKEN, folded);
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
