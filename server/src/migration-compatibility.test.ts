import { beforeEach, describe, expect, test } from "bun:test";
import { checkVerification, startVerification } from "./auth";
import { makeSql } from "./db";
import { getOrCreateDirectDialog } from "./sync";

const TEST_URL = process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test";
const db = makeSql(TEST_URL);

async function makeAccount(phone: string, name: string) {
  const { code } = await startVerification(db, phone);
  return await checkVerification(db, phone, code, "ios", `${name}'s iPhone`, name);
}

describe("forward migration and previous-release startup compatibility", () => {
  beforeEach(async () => {
    await db`TRUNCATE accounts, otp_challenges RESTART IDENTITY CASCADE`;
  });

  test("all appended event types write successfully and an older reader advances past opaque rows", async () => {
    const alice = await makeAccount("+16505557901", "Alice");
    const bob = await makeAccount("+16505557902", "Bob");
    const dialog = await getOrCreateDirectDialog(db, alice.accountId, bob.accountId);
    const appendedTypes = [
      "message.expired",
      "message.preview_updated",
      "member.role_changed",
      "member.left",
      "dialog.profile_updated",
      "dialog.closed",
      "dialog.access_revoked",
      "dialog.preferences_updated",
      "draft.updated",
      "security.changed",
      "chat_folders.updated",
      "scheduled.created",
      "scheduled.updated",
      "scheduled.canceled",
      "scheduled.failed",
      "pin.updated",
      "dialog.auto_delete_updated",
      "poll.updated",
      "sticker_preferences.updated",
    ];
    const startingPts = Number((await db`
      SELECT pts FROM account_sync_states WHERE account_id = ${alice.accountId}`)[0].pts);
    await db`
      UPDATE account_sync_states
      SET pts = pts + ${appendedTypes.length}
      WHERE account_id = ${alice.accountId}`;
    await db`
      INSERT INTO account_events(account_id, pts, type, dialog_id, actor_account_id)
      SELECT ${alice.accountId}, ${startingPts} + ordinal, type, ${dialog.dialogId}, ${alice.accountId}
      FROM unnest(${db.array(appendedTypes, "text")}::text[]) WITH ORDINALITY
        AS event(type, ordinal)`;

    // This is the previous-release startup contract: account/session rows and the monotonic state
    // remain readable, while unrecognized event payloads are treated as opaque and skipped.
    const previousStartup = (await db`
      SELECT account.status, state.pts
      FROM accounts account
      JOIN account_sync_states state ON state.account_id = account.id
      WHERE account.id = ${alice.accountId}`)[0];
    const opaquePage = await db`
      SELECT pts, type FROM account_events
      WHERE account_id = ${alice.accountId} AND pts > ${startingPts}
      ORDER BY pts`;
    expect(previousStartup.status).toBe("active");
    expect(Number(previousStartup.pts)).toBe(startingPts + appendedTypes.length);
    expect(opaquePage.map((row: any) => row.type)).toEqual(appendedTypes);
    expect(Number(opaquePage.at(-1)?.pts)).toBe(Number(previousStartup.pts));

    const constraint = (await db`
      SELECT pg_get_constraintdef(oid) AS definition
      FROM pg_constraint
      WHERE conrelid = 'account_events'::regclass
        AND conname = 'account_events_type_check'`)[0];
    expect(String(constraint.definition)).toContain("draft.updated");
    expect(String(constraint.definition)).toContain("dialog.preferences_updated");
    expect(String(constraint.definition)).toContain("security.changed");
    expect(String(constraint.definition)).toContain("chat_folders.updated");
    expect(String(constraint.definition)).toContain("scheduled.created");
    expect(String(constraint.definition)).toContain("pin.updated");
    expect(String(constraint.definition)).toContain("sticker_preferences.updated");
    expect(await db`
      SELECT name FROM schema_migrations
      WHERE name = 'account-events-type-v7'`).toHaveLength(1);
  });
});
