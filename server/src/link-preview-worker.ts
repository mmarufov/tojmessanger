import { sql } from "./db";
import { startLinkPreviewWorker } from "./link-previews";

const stop = startLinkPreviewWorker(sql, { pollMilliseconds: 2_000 });

async function shutdown(): Promise<void> {
  await stop();
  await sql.end();
  process.exit(0);
}

process.on("SIGINT", () => void shutdown());
process.on("SIGTERM", () => void shutdown());
