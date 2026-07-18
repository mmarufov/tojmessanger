import type { SQL } from "bun";

/** Acquire deterministic transaction-scoped advisory locks for shared mutation boundaries. */
export async function lockMutationKeys(sql: SQL, keys: string[]): Promise<void> {
  const ordered = [...new Set(keys)].sort();
  for (const key of ordered) {
    await sql`SELECT pg_advisory_xact_lock(hashtextextended(${key}, 0))`;
  }
}

export function accountMutationKey(accountId: string): string {
  return `account-mutation:${accountId}`;
}

export async function lockAccountMutations(sql: SQL, accountIds: string[]): Promise<void> {
  await lockMutationKeys(sql, accountIds.map(accountMutationKey));
}
