# Toj cloud operations

This file documents public, provider-neutral procedures. Keep hostnames, credentials, phone numbers,
database URLs, encryption identities, and other deployment values in the server secret store or local
gitignored notes.

## Probes and request logs

- `GET /health` is process liveness and does not touch PostgreSQL.
- `GET /ready` checks PostgreSQL and reports only `configured`/`development`/`disabled` provider
  state. It returns `503` until the complete Saved Messages, dialog-preference, and
  draft/media-group catalog contracts are present: exact runtime columns/defaults/nullability,
  validated checks, conflict uniqueness, required indexes, mixed-writer/deletion/compatibility
  triggers, versioned contract markers, completed migration cursors, and empty reconciliation
  state. These requirements remain active even when rollout switches are off. A database failure
  returns `500`; deployment tooling must require `200` before switching traffic.
- Every HTTP response includes `X-Request-ID`. A safe incoming value is preserved; malformed values
  are replaced. JSON request logs contain only time, request ID, method, normalized route, status,
  and duration—never query strings, bodies, bearer tokens, phone numbers, or account IDs.
- `GET /metrics` exists only when `TOJ_METRICS_TOKEN` is set and requires that value as a bearer token.
  Metrics use normalized route labels to avoid secrets and unbounded label cardinality. Preference
  metrics remain available before expand and report `toj_dialog_preference_schema_available 0`;
  retained idempotency size uses PostgreSQL's planner estimate rather than scanning the permanently
  retained dedupe table.

## Maintenance

The server runs an hourly, bounded cleanup. It repeatedly claims eligible rows with `SKIP LOCKED`
until the row or runtime budget is exhausted. Defaults are 1,000 rows per table per pass, 10,000 total
rows, and five seconds; deployments can tune `TOJ_MAINTENANCE_BATCH_SIZE`,
`TOJ_MAINTENANCE_MAX_ROWS_PER_TICK`, and `TOJ_MAINTENANCE_MAX_RUNTIME_MS`.

Cleanup covers expired OTP challenges older than 24 hours, expired bootstrap snapshots, and terminal
push deliveries older than seven days. Incomplete media uploads are resumable for 24 hours and are
then removed with their encrypted chunks; expired upload-attempt rate records and unattached
completed media are also removed. Completed dialog-preference idempotency records are retained until
account deletion because an offline client can retry a lost response after any fixed cleanup window.
Pending records are also never aged out. Message history and attached media are not deleted by this
worker; account events follow the separately configured synchronization retention floor.

Only abandoned `pending` send claims expire after 24 hours. Completed send receipts remain durable so
a device retrying after days can recover the canonical `client_msg_id`.

## Encrypted group-call rollout and drain

Group calls are dark by default. Production requires managed LiveKit Cloud because this version
uses the provider's room-token revocation cutoff when membership changes; the server rejects a
self-hosted LiveKit configuration in production. Keep these values in the deployment secret store:

- `TOJ_GROUPS_V1_ENABLED=1`
- `TOJ_GROUP_CALLS_ENABLED=1`
- `TOJ_GROUP_CALLS_SFU_READY=1`
- `TOJ_GROUP_CALLS_E2EE_REQUIRED=1`
- `TOJ_LIVEKIT_URL`, `TOJ_LIVEKIT_API_KEY`, and `TOJ_LIVEKIT_API_SECRET`
- `TOJ_LIVEKIT_DEPLOYMENT=cloud`
- `TOJ_GROUP_CALLS_ALLOWLIST` and `TOJ_GROUP_CALLS_ROLLOUT_PERCENT` (default zero)
- `TOJ_GROUP_SCREEN_SHARING_ENABLED` and `TOJ_GROUP_SCREEN_SHARING_READY` (both must be `1`)

Deploy in this order:

1. Run the database migration with admission off. Require `GET /ready` to return `200`; the exact
   group-call schema contract is checked even while the feature is disabled.
2. Deploy the server and LiveKit credentials with an empty allowlist and zero-percent rollout.
   Confirm `toj_group_call_schema_available 1` and that the SFU backlog metrics are zero.
3. Ship the compatible iOS build and its provisioned ReplayKit broadcast extension. Screen sharing
   stays independently off until both screen-sharing switches are set.
4. Allowlist internal accounts, then increase the deterministic rollout percentage in stages.
   Stop expansion on any sustained SFU backlog, lease cleanup, rekey, capacity, thermal, or network
   regression.

To drain safely, first set `TOJ_GROUP_CALLS_ROLLOUT_PERCENT=0` and clear the allowlist while keeping
the base group-call switch, SFU-ready switch, E2EE requirement, and LiveKit credentials in place.
This blocks new starts and joins while existing heartbeats, leaves, membership fencing, and the
durable SFU reconciliation worker continue. End remaining rooms through the normal admin controls or
wait for them to close. Do not turn off `TOJ_GROUP_CALLS_ENABLED`, remove the credentials, or stop
the SFU worker until all of these gauges reach zero:

- `toj_group_call_active_rooms`
- `toj_group_call_rekeying_rooms`
- `toj_group_call_sfu_pending_states`
- `toj_group_call_sfu_failed_states`
- `toj_group_call_sfu_oldest_pending_seconds`
- `toj_group_call_expired_media_leases`

After the drain, disabling admission is an application rollback; retain the additive tables,
constraints, indexes, and migration markers. Page on a nonzero failed-state gauge, a growing oldest
pending age, or expired leases that survive a cleanup interval. Do not enable beyond internal users
until multi-region SFU capacity, Apple provisioning, physical-device carrier/thermal behavior, and
32-participant load and adversarial security tests have passed.

## Media storage

Media works without an Apple Developer account or a third-party storage provider. Resumable chunks
and thumbnails are AEAD-encrypted before PostgreSQL persistence. Deploy the schema before deploying
clients that send media. These optional server settings are byte counts and are bounded to safe ranges:

- `TOJ_MEDIA_CHUNK_BYTES` (legacy offset-v1 only; default 1048576)
- `TOJ_MEDIA_MAX_OBJECT_BYTES` (default 104857600 / 100 MB; configurable up to 2 GB)
- `TOJ_MEDIA_ACCOUNT_QUOTA_BYTES` (default 5368709120 / 5 GB)
- `TOJ_MEDIA_MAX_ACTIVE_UPLOADS` (default 10)
- `TOJ_MEDIA_MAX_DAILY_UPLOADS` (default 100)

The iOS client keeps downloaded media encrypted on disk and, by default, retains it until the user
clears it. Existing user-selected limits remain authoritative. The low-disk reserve is the only
automatic deletion path: it preserves 5% free space, clamped to 1–5 GB, and surfaces a storage notice
when reclamation occurs. Pending uploads are never evicted; new selections fail cleanly when the local
quota cannot accommodate them.

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

Profile updates are mixed-version safe: an omitted `username` key preserves the current handle,
while explicit JSON `null` or an empty string clears it. New clients send an explicit null when the
user removes a handle. Reject non-string, non-null values rather than interpreting them as clears.

## Profile photo rollout

Profile photos are additive and dark by default. Run the ordinary migration first, deploy the
server with `TOJ_PROFILE_PHOTOS_V1_ENABLED` unset, and confirm that `/v1/capabilities` does not
advertise `profile_photos_v1`. The server admits the feature only when the purpose-constraint
migration, account reference/revision constraints, and durable mutation table are all validated.

Ship the compatible client before setting `TOJ_PROFILE_PHOTOS_V1_ENABLED=1` for an internal
environment. During expansion, monitor the existing route/status metrics for
`/v1/profile/photo`, media upload/complete latency and 4xx responses, plus cleanup backlog. Alert on
sustained 409 growth (stale edits or idempotency misuse), terminal upload validation failures,
unexpected media-download 401/403/404 changes, and a cleanup backlog that does not drain.

Validate with two real accounts and two owner devices under packet loss: set, terminate/relaunch,
conflicting edits, explicit conflict resolution, removal, partner visibility, membership revocation,
and cache eviction/redownload. Roll back by clearing `TOJ_PROFILE_PHOTOS_V1_ENABLED`; canonical
metadata and encrypted pending client work remain intact so a later re-enable can reconcile safely.

## Presence and typing rollout

Presence is dark by default and requires the additive `account_presence` and
`device_presence_leases` contract. Run the migration before deploying this binary; `/ready` fails
closed when the contract or expiry indexes are missing.

- `TOJ_PRESENCE_V1_ENABLED=1` enables the authenticated protocol globally.
- `TOJ_PRESENCE_ALLOWLIST` admits comma-separated internal account UUIDs.
- `TOJ_PRESENCE_ROLLOUT_PERCENT` is a deterministic account rollout and defaults to zero.

Deploy the schema with admission off, ship the compatible client, then validate foreground,
background, force-quit, reconnect, multi-device, group membership, and block behavior with an
allowlisted cohort. Expand only while `toj_presence_expired_leases` stays at zero after a cleanup
interval and `toj_presence_oldest_expired_seconds` does not grow. Presence metrics contain aggregate
counts only; never add account or dialog identifiers as labels.

Rollback by setting the percentage to zero or clearing `TOJ_PRESENCE_V1_ENABLED`. Clients remove
ephemeral online and typing state and show status unavailable; the additive tables and encrypted
last-seen cache can remain. Do not use `devices.last_seen_at` as user presence: background requests
also authenticate devices, while presence_v1 records only foreground leases.

## Account deletion

Account deletion is a reauthenticated two-step flow: authenticated `POST /v1/account/deletion/start`
issues an `account_deletion` OTP, then authenticated `DELETE /v1/account` consumes that purpose-bound
code. Login OTPs cannot delete accounts and deletion OTPs cannot create sessions.

Deletion atomically marks the account deleted, replaces the phone lookup identity and encrypted phone
with non-identifying values, changes the profile name to `Deleted Account`, destroys every device
credential hash and device name, removes push tokens, kills pending push work, removes OTP rows, and
revokes all sessions. Existing message rows remain so other participants do not lose their history and
foreign-key integrity is preserved. A later registration with the same phone creates a new account ID.

Saved Messages is the exception to retained conversation history: it has only the deleting account as
an active member, so account deletion removes that dialog and its messages in the same transaction.
Before removal, any direct/group copy forwarded from that archive has its source-account/dialog/message
foreign keys cleared atomically. The copy retains its immutable `is_forwarded` classification,
ciphertext, and media references, so recipients keep the forwarded content without retaining a dangling
identity or a dependency on the deleted archive. Media owned by the deleted account is removed only
when no retained message still references it.

The same database-owned status trigger purges account-private cloud drafts and attachments,
draft/album replay receipts and mutation budgets, dialog preferences and their requests/budgets,
draft/preference sync events, and bootstrap snapshots. It runs for a raw legacy
`UPDATE accounts SET status = 'deleted'` as well as the current API. Media deletion is reference
checked after all private rows are removed: any surviving message, dialog photo, or another draft
keeps the encrypted object and chunks. The migration reconciles already-deleted accounts before
publishing `account-private-cleanup-v1`.

## Saved Messages rollout

Saved Messages is dark by default. Migrate PostgreSQL before enabling it; API version 5 adds the
authenticated `saved_messages_v1` capability and `POST /v1/dialogs/saved`.

- `TOJ_SAVED_MESSAGES_V1_ENABLED=1` enables the route family globally.
- `TOJ_SAVED_MESSAGES_ALLOWLIST` is a comma-separated list of account UUIDs that bypass percentage
  rollout.
- `TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT` accepts 0 through 100 and defaults to zero.

The route returns `404` and performs no mutation when the global switch or the authenticated
account's rollout bucket is off. Deploy the schema and endpoint at zero percent, ship the compatible
iOS client, then allowlist internal multi-device accounts before increasing deterministic buckets.
Rollback by setting the percentage to zero or clearing the global switch; existing server and
encrypted local data is preserved.

After the compatible client is stable at full rollout, provision existing accounts in bounded,
restart-safe batches:

```bash
NODE_ENV=production \
TOJ_SAVED_MESSAGES_V1_ENABLED=1 \
TOJ_SAVED_MESSAGES_ROLLOUT_PERCENT=100 \
TOJ_SAVED_MESSAGES_BACKFILL_CONFIRM=PROVISION_ALL_ACTIVE_ACCOUNTS \
TOJ_SAVED_MESSAGES_BACKFILL_BATCH_SIZE=100 \
TOJ_SAVED_MESSAGES_BACKFILL_THROTTLE_MS=25 \
bun run backfill:saved-messages
```

The command fails closed unless production mode, the global switch, an explicit 100% rollout, and
the exact confirmation value are all present. It logs aggregate counts only, handles
`SIGINT`/`SIGTERM` between accounts, and stops on a failed batch rather than hot-looping. Durable
worker-owned claims prevent concurrent workers from selecting the same account; abandoned claims
become reclaimable after 15 minutes. A worker refreshes and verifies ownership immediately before
each account, so a reclaimed lease is never processed by its former owner. The throttle is per
processed account, defaults to 25 ms, and is bounded to 60 seconds.

The dialog type constraint deploys in expand/validate/contract phases. `schema-dialogs-expand.sql`
adds the wider constraint as `NOT VALID`, PostgreSQL validates it without blocking ordinary
reads/writes, and `schema-dialogs-swap.sql` holds `ACCESS EXCLUSIVE` only for the short name swap.
The forward marker has its own expand/backfill/contract sequence. Expand adds the column and trigger;
old writers that omit the marker are classified from complete provenance. The temporary partial
index contains only unfinished legacy rows, and the Bun worker advances a durable `(dialog_id,
msg_id)` cursor in bounded transactions. Contract validates the invariant and removes the empty
temporary index. Normal `schema.sql` reruns never update `messages.is_forwarded`, and completed
migrations skip both temporary-index creation and the keyset worker.

Keep Saved Messages at zero percent until both contracts complete. An application rollback is safe
only while these database artifacts remain installed. The account-status trigger performs Saved
archive deletion and provenance detachment at the database boundary, so an older application binary
cannot strand an archive or cascade-delete forwarded copies. The new binary also refuses readiness
and capability advertisement if that trigger or any required catalog object is absent. Never roll
the database contract back while Saved rows may exist; close advertisement/ensure with the feature
switch instead. The mixed-node regression covers old-writer insertion, new-reader derivation, and
account deletion. The production-like migration test is:

```bash
bun run test:migration:forward
```

It refuses non-local databases unless the database name ends in `_migration_test`, loads 100,000
messages, runs concurrent writes during bounded backfill, verifies WAL/runtime budgets and both query
plans, checks interrupted-index cleanup, and reruns the normal migration twice. It does not run the
production Saved-dialog provisioning backfill.

Protected `/metrics` output includes `toj_saved_messages_ensure_total` by bounded result,
ensure duration sum/count, and `toj_saved_messages_invariant_violation_total`. Page immediately on
invariant repairs or sustained ensure errors; none of these series contains account or dialog data.

## Dialog preference rollout

`dialog_preferences_v1` and `PUT /v1/dialogs/:id/preferences` are advertised only when
both switches permit them at process startup:

- `TOJ_DIALOG_PREFERENCES_V1_ENABLED=1` enables the client entrypoint (capability and route).
- `TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED=0` is the behavior kill switch. It suppresses the
  capability/route, disables preference-driven auto-unarchive, and makes every application fanout
  path read the legacy notification mode. Its secure rollout default is enabled when unset so
  existing deployments need only gate the client entrypoint.

With either gate closed, the preference route family hard-404s. The legacy group-notification route
stays available and writes `dialog_members.notification_mode`. The database compatibility trigger
mirrors that value and emits the account PTS update needed by new clients, including while old and
new server nodes overlap. The trigger deliberately remains active when behavior is killed so a
rollback cannot strand a durable legacy mute or create a sync gap.

Readiness always requires every preference table and exact runtime column signature, every primary
or unique constraint used by `ON CONFLICT`, the enabled
`dialog_members_notification_mode_mirror` trigger bound to the final versioned function, the exact
validated `account_events_type_check`, contract version 1 with its completion timestamp, the
completed `dialog_preferences_v1` backfill cursor, and an empty legacy reconciliation table. This is
independent of the rollout switches because ordinary message fanout, direct-dialog creation, and
bootstrap SQL are compiled against the expanded schema. Until all conditions hold, the process must
not receive traffic; capability advertisement, the preference route, and preference-driven fanout
also remain disabled. Rerunning only the expand phase atomically clears the contract marker and
installs the versioned staging trigger, so readiness remains `503` until contract completes again.

Run `bun run migrate` before enabling either client entrypoint. It applies a short-lock expand,
resumable bounded backfill, concurrent indexes, separately validates the replacement event
constraint, then swaps constraints in a short contract transaction. Its final JSON log includes
runtime, rows, batches, legacy reconciliation count, and WAL bytes. Production automation should set
`TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_RUNTIME_MS` and
`TOJ_DIALOG_PREFERENCES_MIGRATION_MAX_WAL_BYTES` to measured deployment limits.

Roll out in this order: migrate/backfill with the entrypoint off, deploy compatible server nodes,
distribute the iOS build, then enable the entrypoint and restart nodes. Confirm API version 5
advertises `dialog_preferences_v1`, preference-route errors remain flat, account `pts` gaps do not
increase, the client retry backlog drains, and muted deliveries are silent while unmuted deliveries
alert. Roll back client entry by clearing `TOJ_DIALOG_PREFERENCES_V1_ENABLED`; kill preference-driven
server behavior by additionally setting `TOJ_DIALOG_PREFERENCES_BEHAVIOR_ENABLED=0`. Stored
pin/archive/mute values and mirrored legacy group mute remain intact for a later re-enable.

Account deletion purges preference rows, idempotency payloads, budget rows, preference events, and
bootstrap snapshots because they are private presentation state. Delivered message history remains
under the separate message-retention contract.

## Cloud drafts and media-group rollout

`cloud_drafts_v1` and `media_groups_v1` remain independently controlled by
`TOJ_CLOUD_DRAFTS_V1_ENABLED` and `TOJ_MEDIA_GROUPS_V1_ENABLED`, but neither capability is advertised
unless the shared draft/media schema manifest is fully ready. The same effective availability is
used by draft hydration, difference/bootstrap sync, draft consumption, draft routes, and grouped
sends, so a partial schema fails closed even if a node is reached outside the load balancer.

Run `bun run migrate` before enabling either switch. The runner validates and swaps the existing
message/event constraints, builds the cleanup/replay indexes, installs the account-private deletion
boundary, reconciles any deleted-account residue in bounded batches, and only then publishes the
`account-private-cleanup-v1` marker. Require `/ready` to return `200`, then verify authenticated and
unauthenticated capability responses before admitting traffic. Rollback is by clearing the two
feature switches; do not remove the database cleanup function or status trigger while any binary
can create draft, album, Saved, or preference state.

## Cloud folders, scheduled delivery, and link-preview rollout

These three features share the cloud-productivity schema migration but have independent account
rollouts and kill switches. Run `bun run migrate` before deploying the compatible binary. Keep every
switch at zero until `/ready` is healthy and the contract marker
`cloud-productivity-contract-v1` exists.

- Chat folders: `TOJ_CHAT_FOLDERS_V1_ENABLED=1`, `TOJ_CHAT_FOLDERS_ROLLOUT_PERCENT=0..100`,
  and optional `TOJ_CHAT_FOLDERS_ALLOWLIST` account UUIDs.
- Scheduled delivery: `TOJ_SCHEDULED_DELIVERY_V1_ENABLED=1` (or
  `TOJ_SCHEDULED_DELIVERY_V1_ACCEPTING=1`), `TOJ_SCHEDULED_DELIVERY_ROLLOUT_PERCENT`, and
  optional `TOJ_SCHEDULED_DELIVERY_ALLOWLIST`.
- Link previews: `TOJ_LINK_PREVIEWS_V1_ENABLED=1`, `TOJ_LINK_PREVIEWS_ROLLOUT_PERCENT`, and
  optional `TOJ_LINK_PREVIEWS_ALLOWLIST`.

Run the durable workers independently from the HTTP process in production:

```bash
bun run worker:scheduled-delivery
bun run worker:link-preview
```

The HTTP process also starts both workers for local development and single-process test deployments.
Set `TOJ_PRODUCTIVITY_WORKERS_DISABLED=1` there when dedicated worker services are active.
The scheduled-delivery management capability is advertised whenever its schema is complete and the
account is in rollout. A stale scheduled-worker heartbeat does not hide previously accepted rows,
sync updates, or cancellation: reads and cancellation remain available. Only create and reschedule
fail closed with `503 scheduled_worker_unavailable` and `Retry-After` until a heartbeat is fresher
than 30 seconds. Link-preview advertisement still requires its worker heartbeat. Folder capability
does not require a worker.

Deploy in this order: expand/validate/contract migration; compatible HTTP nodes with all feature
switches off; both worker services; iOS build; internal allowlists; 1%, 10%, 50%, then 100% account
rollout. Before each increase, verify no account PTS gaps, no growing `processing` leases older than
30 seconds, no stale worker heartbeats, stable dispatch lag, bounded preview failures, and flat 5xx
rates. The migration, route families, account events, maintenance cleanup, and encrypted columns
must remain installed during an application rollback.

Scheduled delivery is server-owned after an idempotent create is accepted, even if the response is
lost. The iOS client durably stages creates and records the attempt before the HTTP commit point; an
uncertain create is resolved with the same key before cancellation, so it cannot become an orphaned
server schedule. Cancel and reschedule intents are also stored locally before networking. Workers
use `FOR UPDATE SKIP LOCKED`, expiring leases, stable
client message IDs, and the existing send idempotency ledger. Dispatch revalidates dialog access,
media ownership, replies, and mentions; a missing reply or stale mention is safely dropped while a
lost dialog becomes a permanent sanitized failure. Terminal rows erase message ciphertext and
release scheduled media references. Cancel and worker claim serialize on the schedule row: cancel
wins before claim, while a processing response means dispatch already owns the linearization point.

Link preview fetching never runs in the request transaction. The request stores only encrypted URLs
and a keyed lookup digest, then a worker resolves every DNS result, rejects private/loopback/link-local
and mapped addresses, pins the selected address, rechecks the connected peer, repeats the policy on
every redirect, permits only HTTP/HTTPS standard ports without credentials, and enforces byte,
time, redirect, image-pixel, and output limits. JavaScript is never executed. Metadata, URLs, and
normalized JPEG assets remain encrypted at rest. Asset downloads require current dialog membership.
Turning the preview switch off stops new jobs and payload sync without affecting text delivery.

Immediate rollback is account percentage zero (and empty allowlists), followed by clearing the
feature switch. To pause only new scheduled acceptance while preserving management, leave the
account rollout enabled and stop the worker: clients retain read/cancel access while create and
reschedule receive retryable `503`s. Do not remove the management route or schema while accepted
schedules remain; wait until `scheduled` and `processing` rows drain or retain the worker service.
The preview worker can be stopped after closing preview
acceptance; pending previews degrade to ordinary links. Folder rows and all local SQLCipher copies
remain for later re-enable.

Useful aggregate checks (never select encrypted payload columns into logs):

```sql
SELECT state, count(*), max(now() - deliver_at) AS max_lag
FROM scheduled_deliveries GROUP BY state;
SELECT worker_kind, max(last_seen_at) AS freshest
FROM worker_heartbeats GROUP BY worker_kind;
SELECT state, count(*) FROM link_preview_cache_entries GROUP BY state;
```


## Voice calls and TURN readiness

`voice_calls_v1` is advertised only when all of the following are configured:

- `TOJ_VOICE_CALLS_ENABLED=1`
- APNs credentials are configured, including the PushKit topic when it differs from `<TOJ_APNS_TOPIC>.voip`
- `TOJ_TURN_URLS` contains the comma-separated TURN UDP/TCP/TLS endpoints
- `TOJ_TURN_SHARED_SECRET` contains the coturn REST-auth shared secret
- `TOJ_TURN_READY=1` is set by deployment automation only after TURN allocation and relay health probes pass

The APNs provider settings are:

- `TOJ_APNS_TEAM_ID` and `TOJ_APNS_KEY_ID` from the Apple Developer account
- `TOJ_APNS_PRIVATE_KEY_BASE64`, containing the complete APNs `.p8` key encoded as base64
- `TOJ_APNS_TOPIC` (defaults to `com.toj.Toj`)
- `TOJ_APNS_VOIP_TOPIC` (defaults to `<TOJ_APNS_TOPIC>.voip`)

All of the first three values must be set together. The app identifier, provisioning profile, and
signed `aps-environment` entitlement must match the APNs topic and environment. A partial APNs
configuration fails server startup; no APNs configuration keeps calls unavailable.

For two TURN nodes, include all usable client transports in measured-preference order, for example:

```text
TOJ_TURN_URLS=turn:turn-a.example.com:3478?transport=udp,turn:turn-a.example.com:3478?transport=tcp,turns:turn-a.example.com:443?transport=tcp,turn:turn-b.example.com:3478?transport=udp,turn:turn-b.example.com:3478?transport=tcp,turns:turn-b.example.com:443?transport=tcp
TOJ_STUN_URLS=stun:turn-a.example.com:3478,stun:turn-b.example.com:3478
```

`TOJ_STUN_URLS` is optional, but configuring both nodes is recommended so ICE can discover direct
server-reflexive paths before falling back to relay. Restart the call-control process after changing
any APNs, TURN, STUN, or voice-readiness setting because capability readiness is calculated at
startup.

`video_calls_v1` additionally requires `TOJ_VIDEO_CALLS_ENABLED=1` and
`TOJ_TURN_VIDEO_READY=1`. The latter may be set only after both failure-independent TURN regions
pass sustained video-capacity tests with UDP, TCP, and TLS 443. Each allocation starts with
`max-bps=512000` bytes/second (about 4.096 Mbps aggregate); the client still caps one outbound
camera stream at 1.5 Mbps. Set `total-quota`, `bps-capacity`, and provider egress budgets from the
measured node limit, not an estimate.

Video eligibility is deterministic per account. `TOJ_VIDEO_CALLS_ALLOWLIST` is a comma-separated
list of internal account UUIDs and always takes precedence. `TOJ_VIDEO_CALLS_ROLLOUT_PERCENT` accepts
0 through 100 and defaults to zero. Use 5 for 48 hours, 25 for 72 hours, and then 100 only after all
release gates pass. Roll back by setting the percentage to zero and restarting: new video calls are
rejected, new audio calls select media profile 1, and in-flight profile-2 calls retain the immutable
selection policy stored when they were created.

The repository's [Video Calls v1 release report](../VIDEO_CALLS_RELEASE_REPORT.md) is the
authoritative checklist for provisioning, two-region TURN capacity, physical-device coverage, and
quantitative rollout gates. Do not set either video readiness flag based on simulator evidence alone.

Clear `TOJ_TURN_READY` or `TOJ_VOICE_CALLS_ENABLED` and restart the process to stop advertising and
accepting new calls. Clear either video readiness flag to stop advertising video globally, or set
the video rollout percentage to zero for a staged rollback. Existing call action, signaling, and
termination routes remain available so in-progress calls can finish cleanly.

For a first rollout, migrate PostgreSQL and deploy with both readiness flags off. Prove authenticated
allocations through each advertised UDP/TCP/TLS path from outside the TURN networks, set
`TOJ_TURN_READY=1` and `TOJ_VOICE_CALLS_ENABLED=1`, restart, then require
`GET /v1/capabilities` to contain `voice_calls_v1` before distributing the calling build.

Only active iOS devices with a complete encrypted PushKit registration are ring targets. TURN
credentials are scoped to the initiating or first-answer device, live for 60 minutes, and are
replaced when fewer than 15 minutes remain. Once key confirmation completes, each encrypted signal
(including the client's periodic encrypted control heartbeat) renews a 120-second active-call lease.
Clients heartbeat at roughly 30 seconds so a process crash, revoked device, or deleted account
cannot strand an active call while ordinary transient network loss still has recovery room.

Use `TOJ_CALL_NOTIFY_DATABASE_URL` for the dedicated PostgreSQL `LISTEN` connection when it differs
from `DATABASE_URL`. Call events are durable database rows and notifications are only low-latency
wake-ups, so clients recover a listener outage through `GET /v1/calls/active` and event catch-up.
Encrypted signaling is removed no later than ten minutes after termination; sanitized call metadata
is retained for 30 days. The terminal transition writes a `call_history_outbox` record atomically;
request and cleanup workers retry its idempotent service message until delivered, preserving the
original caller account identifier even when account deletion ended the call.
