import { $, type SQL } from "bun";
import { expect, test } from "bun:test";
import { startCloudServer } from "./cloud";
import { makeSql } from "./db";
import { draftMediaSchemaState } from "./draft-media-readiness";

const sourceURL = new URL(
  process.env.TEST_DATABASE_URL ?? "postgres://localhost:5432/toj_test",
);
const adminURL = new URL(sourceURL);
adminURL.pathname = "/postgres";
const serverRoot = new URL("..", import.meta.url).pathname;

async function withDisposableDatabase(
  body: (sql: SQL) => Promise<void>,
): Promise<void> {
  const databaseName = `toj_draft_ready_${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
  const databaseURL = new URL(sourceURL);
  databaseURL.pathname = `/${databaseName}`;
  let sql: SQL | null = null;
  try {
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${
      `CREATE DATABASE ${databaseName}`
    }`.quiet();
    const migration = Bun.spawn(["bun", "run", "src/migrate.ts"], {
      cwd: serverRoot,
      env: { ...process.env, DATABASE_URL: databaseURL.toString() },
      stdout: "pipe",
      stderr: "pipe",
    });
    const [exitCode, stdout, stderr] = await Promise.all([
      migration.exited,
      new Response(migration.stdout).text(),
      new Response(migration.stderr).text(),
    ]);
    if (exitCode !== 0) {
      throw new Error(`migration failed (${exitCode}): ${stderr || stdout}`);
    }
    sql = makeSql(databaseURL.toString());
    await body(sql);
  } finally {
    if (sql) await sql.close();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${`
      SELECT pg_terminate_backend(pid)
      FROM pg_stat_activity
      WHERE datname = '${databaseName}' AND pid <> pg_backend_pid()
    `}`.quiet();
    await $`psql ${adminURL.toString()} -v ON_ERROR_STOP=1 -c ${
      `DROP DATABASE IF EXISTS ${databaseName}`
    }`.quiet();
  }
}

async function withFeatureSwitches(body: () => Promise<void>): Promise<void> {
  const previousDrafts = process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
  const previousGroups = process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
  process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = "1";
  process.env.TOJ_MEDIA_GROUPS_V1_ENABLED = "1";
  try {
    await body();
  } finally {
    if (previousDrafts === undefined) delete process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED;
    else process.env.TOJ_CLOUD_DRAFTS_V1_ENABLED = previousDrafts;
    if (previousGroups === undefined) delete process.env.TOJ_MEDIA_GROUPS_V1_ENABLED;
    else process.env.TOJ_MEDIA_GROUPS_V1_ENABLED = previousGroups;
  }
}

async function expectTrafficAndCapabilities(
  sql: SQL,
  ready: boolean,
): Promise<void> {
  await withFeatureSwitches(async () => {
    const server = startCloudServer(0, sql, null, null);
    const base = `http://127.0.0.1:${server.port}`;
    try {
      const readyResponse = await fetch(`${base}/ready`);
      expect(readyResponse.status).toBe(ready ? 200 : 503);
      const capabilities = await (await fetch(`${base}/v1/capabilities`)).json() as {
        capabilities: string[];
      };
      expect(capabilities.capabilities.includes("cloud_drafts_v1")).toBe(ready);
      expect(capabilities.capabilities.includes("media_groups_v1")).toBe(ready);
    } finally {
      await server.stop(true);
    }
  });
}

test("complete draft/media schema admits traffic and advertises both capabilities", async () => {
  await withDisposableDatabase(async (sql) => {
    expect(await draftMediaSchemaState(sql, { bypassCache: true })).toEqual({
      ready: true,
      missingTables: [],
      missingColumns: [],
      invalidColumns: [],
      missingUniqueConstraints: [],
      missingCheckConstraints: [],
      missingIndexes: [],
      missingMigrations: [],
      accountEventConstraintReady: true,
      accountCleanupReady: true,
    });
    await expectTrafficAndCapabilities(sql, true);
  });
}, 120_000);

const FEATURE_TABLES = [
  "account_dialog_drafts",
  "draft_attachments",
  "draft_mutation_requests",
  "draft_mutation_tombstones",
  "draft_mutation_budgets",
  "media_group_send_requests",
  "media_group_send_tombstones",
  "media_group_send_budgets",
] as const;

test("every partial feature-table schema fails readiness and capability advertisement", async () => {
  for (const table of FEATURE_TABLES) {
    await withDisposableDatabase(async (sql) => {
      await sql.unsafe(`DROP TABLE public.${table} CASCADE`);
      const state = await draftMediaSchemaState(sql, { bypassCache: true });
      expect(state.ready, table).toBe(false);
      expect(state.missingTables, table).toContain(table);
      await expectTrafficAndCapabilities(sql, false);
    });
  }
}, 240_000);

const ROLLBACK = new Error("rollback readiness mutation");

async function expectRejectedInsideRollback(
  sql: SQL,
  mutate: (tx: SQL) => Promise<void>,
  assertion: (state: Awaited<ReturnType<typeof draftMediaSchemaState>>) => void,
): Promise<void> {
  try {
    await sql.begin(async (tx) => {
      await mutate(tx as unknown as SQL);
      const state = await draftMediaSchemaState(
        tx as unknown as SQL,
        { bypassCache: true },
      );
      expect(state.ready).toBe(false);
      assertion(state);
      throw ROLLBACK;
    });
  } catch (error) {
    if (error !== ROLLBACK) throw error;
  }
  expect((await draftMediaSchemaState(sql, { bypassCache: true })).ready).toBe(true);
}

test("shared columns, exact checks, indexes, migration markers, and cleanup topology fail closed", async () => {
  await withDisposableDatabase(async (sql) => {
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER TABLE public.send_requests
          DROP COLUMN draft_consume_operation_id`;
      },
      (state) => {
        expect(state.missingColumns)
          .toContain("send_requests.draft_consume_operation_id");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER TABLE public.dialogs
          DROP COLUMN photo_media_id CASCADE`;
      },
      (state) => {
        expect(state.missingColumns).toContain("dialogs.photo_media_id");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER TABLE public.draft_mutation_requests
          ALTER COLUMN status DROP DEFAULT`;
      },
      (state) => {
        expect(state.invalidColumns).toContain("draft_mutation_requests.status");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER TABLE public.messages
          DROP CONSTRAINT messages_media_group_shape_check`;
      },
      (state) => {
        expect(state.missingCheckConstraints)
          .toContain("messages_media_group_shape_check");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`DROP INDEX public.messages_media_group_idx`;
      },
      (state) => {
        expect(state.missingIndexes).toContain("messages_media_group_idx");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          DELETE FROM public.schema_migrations
          WHERE name = 'account-private-cleanup-v1'`;
      },
      (state) => {
        expect(state.missingMigrations).toContain("account-private-cleanup-v1");
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER FUNCTION public.toj_cleanup_account_private_state_v1(UUID)
          RESET search_path`;
      },
      (state) => {
        expect(state.accountCleanupReady).toBe(false);
      },
    );
    await expectRejectedInsideRollback(
      sql,
      async (tx) => {
        await tx`
          ALTER FUNCTION public.toj_cleanup_saved_messages_for_account(UUID)
          RENAME TO toj_cleanup_saved_messages_for_account_missing`;
      },
      (state) => {
        expect(state.accountCleanupReady).toBe(false);
      },
    );
  });
}, 120_000);
