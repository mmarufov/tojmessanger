export class CallVersionCapabilityError extends Error {}

/** Shared validator for transcript offers and persisted device capability arrays. */
export function normalizeCallVersionCapabilities(
  value: unknown,
  fallback: number[] = [1],
): number[] {
  if (value == null) return [...fallback];
  if (!Array.isArray(value) || value.length === 0 || value.length > 16
    || value.some((entry) => !Number.isSafeInteger(entry)
      || Number(entry) <= 0 || Number(entry) > 0xffff)) {
    throw new CallVersionCapabilityError("version offer is invalid");
  }
  const versions = value.map(Number);
  if (versions.some((entry, index) => index > 0 && entry <= versions[index - 1])) {
    throw new CallVersionCapabilityError("version offers must be sorted and unique");
  }
  return versions;
}
