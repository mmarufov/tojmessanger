#!/usr/bin/env bash
set -euo pipefail
umask 077

: "${TOJ_BACKUP_DATABASE_URL:?Set TOJ_BACKUP_DATABASE_URL}"
: "${TOJ_BACKUP_DIR:?Set TOJ_BACKUP_DIR}"
: "${TOJ_BACKUP_AGE_RECIPIENT:?Set TOJ_BACKUP_AGE_RECIPIENT}"

for command in pg_dump age openssl; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done

mkdir -p "$TOJ_BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
final="$TOJ_BACKUP_DIR/toj-$timestamp.dump.age"
partial="$final.partial"

trap 'rm -f "$partial"' EXIT INT TERM
pg_dump "$TOJ_BACKUP_DATABASE_URL" --format=custom --compress=9 --no-owner --no-acl \
  | age --recipient "$TOJ_BACKUP_AGE_RECIPIENT" --output "$partial"
test -s "$partial"
mv "$partial" "$final"
openssl dgst -sha256 "$final" | sed 's/^.*= //' > "$final.sha256"
chmod 600 "$final" "$final.sha256"
printf '%s\n' "$final"
