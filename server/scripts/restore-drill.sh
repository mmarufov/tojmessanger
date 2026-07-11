#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${TOJ_BACKUP_FILE:?Set TOJ_BACKUP_FILE to a .dump.age backup}"
: "${TOJ_BACKUP_AGE_IDENTITY:?Set TOJ_BACKUP_AGE_IDENTITY}"
: "${TOJ_RESTORE_DATABASE_URL:?Set TOJ_RESTORE_DATABASE_URL to an empty disposable database}"
: "${TOJ_RESTORE_CONFIRM:?Set TOJ_RESTORE_CONFIRM=DISPOSABLE_DATABASE}"

test "$TOJ_RESTORE_CONFIRM" = "DISPOSABLE_DATABASE" || { echo "restore confirmation rejected" >&2; exit 1; }
for command in age pg_restore psql openssl; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done
test -f "$TOJ_BACKUP_FILE.sha256"
expected_hash="$(tr -d '[:space:]' < "$TOJ_BACKUP_FILE.sha256")"
actual_hash="$(openssl dgst -sha256 "$TOJ_BACKUP_FILE" | sed 's/^.*= //')"
test -n "$expected_hash" && test "$actual_hash" = "$expected_hash" \
  || { echo "backup checksum mismatch" >&2; exit 1; }

existing_tables="$(psql "$TOJ_RESTORE_DATABASE_URL" -Atqc "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")"
test "$existing_tables" = "0" || { echo "refusing to restore into a non-empty database" >&2; exit 1; }

archive="$(mktemp "${TMPDIR:-/tmp}/toj-restore.XXXXXX.dump")"
trap 'rm -f "$archive"' EXIT INT TERM
age --decrypt --identity "$TOJ_BACKUP_AGE_IDENTITY" --output "$archive" "$TOJ_BACKUP_FILE"
pg_restore --list "$archive" >/dev/null
pg_restore --exit-on-error --no-owner --no-acl --dbname "$TOJ_RESTORE_DATABASE_URL" "$archive"

psql "$TOJ_RESTORE_DATABASE_URL" -v ON_ERROR_STOP=1 -Atqc \
  "SELECT CASE WHEN to_regclass('public.accounts') IS NOT NULL
                    AND to_regclass('public.devices') IS NOT NULL
                    AND to_regclass('public.messages') IS NOT NULL
                    AND to_regclass('public.account_events') IS NOT NULL
               THEN 'restore-ok' ELSE 'restore-incomplete' END" \
  | grep -qx 'restore-ok'
echo "restore drill passed"
