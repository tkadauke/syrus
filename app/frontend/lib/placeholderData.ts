import type { QueryKey } from "@tanstack/react-query"

/**
 * Identity-aware replacement for `keepPreviousData`.
 *
 * Returns a `placeholderData` function that keeps the previous query's data only
 * when the key segments at `identityIndexes` are deeply equal between the
 * previous and current query keys. This lets pagination/filter/ref changes
 * within one entity stay smooth while never rendering one entity's content
 * under another entity's key. Collection/filter-only screens should keep using
 * plain `keepPreviousData`.
 */
export function keepPreviousDataWithin(
  currentKey: QueryKey,
  identityIndexes: readonly number[]
) {
  return <TData>(previousData: TData | undefined, previousQuery: { queryKey: QueryKey } | undefined): TData | undefined => {
    const previousKey = previousQuery?.queryKey
    if (!previousKey) return undefined
    const same = identityIndexes.every((index) => index < previousKey.length && index < currentKey.length && sameSegment(previousKey[index], currentKey[index]))
    return same ? previousData : undefined
  }
}

function sameSegment(a: unknown, b: unknown): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}
