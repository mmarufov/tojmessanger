import { sql } from "./db";
import { startScheduledDeliveryWorker } from "./scheduled-deliveries";

const stop = startScheduledDeliveryWorker(sql, { pollMilliseconds: 1_000 });

async function shutdown(): Promise<void> {
  stop();
  await sql.end();
  process.exit(0);
}

process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
