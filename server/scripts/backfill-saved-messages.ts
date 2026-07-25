import { sql } from "../src/db";
import {
  ensureSavedMessages,
  savedMessagesBackfillCandidates,
} from "../src/saved-messages";

const rawBatchSize = Number(process.env.TOJ_SAVED_MESSAGES_BACKFILL_BATCH_SIZE ?? "100");
const batchSize = Number.isSafeInteger(rawBatchSize)
  ? Math.max(1, Math.min(rawBatchSize, 1_000))
  : 100;
let stopping = false;
let created = 0;
let existing = 0;
let repaired = 0;
const startedAt = performance.now();

process.on("SIGINT", () => { stopping = true; });
process.on("SIGTERM", () => { stopping = true; });

while (!stopping) {
  const candidates = await savedMessagesBackfillCandidates(sql, batchSize);
  if (candidates.length === 0) break;
  let failures = 0;
  for (const accountId of candidates) {
    if (stopping) break;
    try {
      const result = await ensureSavedMessages(sql, accountId);
      if (result.created) created += 1;
      else if (result.repaired) repaired += 1;
      else existing += 1;
    } catch {
      failures += 1;
    }
  }
  console.log(JSON.stringify({
    event: "saved_messages.backfill_batch",
    processed: candidates.length,
    created,
    existing,
    repaired,
    failures,
  }));
  // Failed accounts still match the next query. Stop instead of hot-looping or silently skipping.
  if (failures > 0) {
    throw new Error(`saved messages backfill stopped after ${failures} failures`);
  }
  await Bun.sleep(25);
}

console.log(JSON.stringify({
  event: "saved_messages.backfill_complete",
  stopped: stopping,
  created,
  existing,
  repaired,
  durationMs: Math.round(performance.now() - startedAt),
}));
await sql.end();
