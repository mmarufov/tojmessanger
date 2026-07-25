import { sql } from "../src/db";
import {
  claimSavedMessagesBackfillAccounts,
  completeSavedMessagesBackfillClaim,
  ensureSavedMessages,
  failSavedMessagesBackfillClaim,
  refreshSavedMessagesBackfillClaim,
  requireSavedMessagesBackfillAuthorization,
  SavedMessagesError,
  savedMessagesBackfillThrottleMs,
} from "../src/saved-messages";

requireSavedMessagesBackfillAuthorization();

const rawBatchSize = Number(process.env.TOJ_SAVED_MESSAGES_BACKFILL_BATCH_SIZE ?? "100");
const batchSize = Number.isSafeInteger(rawBatchSize)
  ? Math.max(1, Math.min(rawBatchSize, 1_000))
  : 100;
const throttleMs = savedMessagesBackfillThrottleMs();
const workerId = crypto.randomUUID();
let stopping = false;
let created = 0;
let existing = 0;
let repaired = 0;
let unavailable = 0;
let lostOwnership = 0;
const startedAt = performance.now();

process.on("SIGINT", () => { stopping = true; });
process.on("SIGTERM", () => { stopping = true; });

while (!stopping) {
  const claims = await claimSavedMessagesBackfillAccounts(sql, workerId, batchSize);
  if (claims.length === 0) break;
  let failures = 0;
  for (const claim of claims) {
    if (stopping) break;
    if (!await refreshSavedMessagesBackfillClaim(sql, claim)) {
      // A stale lease may have been reclaimed while an earlier account was throttled. Never act
      // after losing the exact durable claim.
      lostOwnership += 1;
    } else {
      try {
        const result = await ensureSavedMessages(sql, claim.accountId);
        if (result.created) created += 1;
        else if (result.repaired) repaired += 1;
        else existing += 1;
        await completeSavedMessagesBackfillClaim(sql, claim);
      } catch (error) {
        if (error instanceof SavedMessagesError && error.code === "account_unavailable") {
          unavailable += 1;
          await completeSavedMessagesBackfillClaim(sql, claim, "account_unavailable");
        } else {
          failures += 1;
          await failSavedMessagesBackfillClaim(
            sql,
            claim,
            error instanceof SavedMessagesError ? error.code : "unexpected_error",
          );
        }
      }
    }
    if (throttleMs > 0 && !stopping) await Bun.sleep(throttleMs);
  }
  console.log(JSON.stringify({
    event: "saved_messages.backfill_batch",
    processed: claims.length,
    created,
    existing,
    repaired,
    unavailable,
    lostOwnership,
    failures,
  }));
  // Failed accounts still match the next query. Stop instead of hot-looping or silently skipping.
  if (failures > 0) {
    throw new Error(`saved messages backfill stopped after ${failures} failures`);
  }
}

console.log(JSON.stringify({
  event: "saved_messages.backfill_complete",
  stopped: stopping,
  created,
  existing,
  repaired,
  unavailable,
  lostOwnership,
  durationMs: Math.round(performance.now() - startedAt),
}));
await sql.end();
