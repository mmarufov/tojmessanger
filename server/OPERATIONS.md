# Toj cloud operations

This file documents public, provider-neutral procedures. Keep hostnames, credentials, phone numbers,
database URLs, encryption identities, and other deployment values in the server secret store or local
gitignored notes.

## Probes and request logs

- `GET /health` is process liveness and does not touch PostgreSQL.
- `GET /ready` checks PostgreSQL and reports only `configured`/`development`/`disabled` provider state. A database
  failure returns `500`, so deployment tooling must require a `200` before switching traffic.
- Every HTTP response includes `X-Request-ID`. A safe incoming value is preserved; malformed values
  are replaced. JSON request logs contain only time, request ID, method, normalized route, status,
  and duration—never query strings, bodies, bearer tokens, phone numbers, or account IDs.
- `GET /metrics` exists only when `TOJ_METRICS_TOKEN` is set and requires that value as a bearer token.
  Metrics use normalized route labels to avoid secrets and unbounded label cardinality.

## Maintenance

The server runs an hourly, bounded cleanup. Each table deletes at most 1,000 eligible rows per run:
expired OTP challenges older than 24 hours, expired bootstrap snapshots, and terminal push deliveries
older than seven days. Incomplete media uploads are resumable for 24 hours and are then removed with
their encrypted chunks; expired upload-attempt rate records and unattached completed media are also
removed. Message history, attached media, and the account event log are never deleted by this worker.

## Media storage

Media works without an Apple Developer account or a third-party storage provider. Resumable chunks
and thumbnails are AEAD-encrypted before PostgreSQL persistence. Deploy the schema before deploying
clients that send media. These optional server settings are byte counts and are bounded to safe ranges:

- `TOJ_MEDIA_CHUNK_BYTES` (legacy offset-v1 only; default 1048576)
- `TOJ_MEDIA_MAX_OBJECT_BYTES` (default 26214400)
- `TOJ_MEDIA_ACCOUNT_QUOTA_BYTES` (default 262144000)
- `TOJ_MEDIA_MAX_ACTIVE_UPLOADS` (default 10)
- `TOJ_MEDIA_MAX_DAILY_UPLOADS` (default 100)

The iOS client additionally keeps an encrypted, automatically evicted 200 MB download cache. Pending
uploads are never evicted; new selections fail cleanly when the local quota cannot accommodate them.

API version 3 adds `media_multipart_v2`. Clients using it upload numbered, idempotent parts out of
order with up to three concurrent requests: 256 KiB parts through 10 MiB and 512 KiB parts above
10 MiB. Completion checks the exact part layout, declared byte count, SHA-256, media signature, and
photo dimensions before making an object usable. The offset-v1 route remains available for older
clients and cannot write into a multipart upload.

## Encrypted backups

`scripts/backup-postgres.sh` streams a PostgreSQL custom-format dump directly into `age`, writes it
atomically with mode `0600`, and creates a SHA-256 sidecar. Required environment variables:

- `TOJ_BACKUP_DATABASE_URL`
- `TOJ_BACKUP_DIR`
- `TOJ_BACKUP_AGE_RECIPIENT` (public recipient only)

Keep the age private identity off the application server. Copy both the encrypted backup and its
checksum to separate storage. Retention deletion is intentionally outside this script so a broken job
cannot erase the last good backup.

The production timer templates are under `ops/`. Install the script separately at
`/usr/local/sbin/toj-backup-postgres` rather than executing it inside a private application directory;
the `postgres` service user should not be granted traversal access to the application files. Store the
three variables above in `/etc/toj/backup.env`, readable only by root and the database service group.

## Restore drill

Run `scripts/restore-drill.sh` against a newly created, empty, disposable PostgreSQL database. It
verifies the checksum, decrypts to a private temporary file, validates the archive, refuses a
non-empty target, restores with `--exit-on-error`, and verifies critical tables. It requires:

- `TOJ_BACKUP_FILE`
- `TOJ_BACKUP_AGE_IDENTITY`
- `TOJ_RESTORE_DATABASE_URL`
- `TOJ_RESTORE_CONFIRM=DISPOSABLE_DATABASE`

Do not point the drill at production. A restore is not considered proven until this command passes.

## Legacy WebSocket rollout switch

`TOJ_ALLOW_LEGACY_WS_QUERY_TOKEN=1` temporarily accepts old clients whose WebSocket bearer token is
in the URL query. New clients use the `Authorization` header. Enable the switch only for a coordinated
upgrade because URLs can appear in proxy and access logs. After all active test installs are updated,
remove the variable from the private service environment and restart the service. The secure default
is off; an unset variable rejects query tokens.

`TOJ_RETURN_OTP=1` is a separate private-development switch that can return the OTP in the auth
response when no SMS provider exists. In production it also requires `TOJ_DEV_OTP_ALLOWLIST`, a
comma-separated server-secret list of the exact international phone numbers permitted to receive a
code in the response. All other numbers fail closed without an SMS adapter. Readiness labels this
mode `development` without exposing the allowlist. Remove both variables as soon as real SMS delivery
is configured.

## Account deletion

Account deletion is a reauthenticated two-step flow: authenticated `POST /v1/account/deletion/start`
issues an `account_deletion` OTP, then authenticated `DELETE /v1/account` consumes that purpose-bound
code. Login OTPs cannot delete accounts and deletion OTPs cannot create sessions.

Deletion atomically marks the account deleted, replaces the phone lookup identity and encrypted phone
with non-identifying values, changes the profile name to `Deleted Account`, destroys every device
credential hash and device name, removes push tokens, kills pending push work, removes OTP rows, and
revokes all sessions. Existing message rows remain so other participants do not lose their history and
foreign-key integrity is preserved. A later registration with the same phone creates a new account ID.
