import { keepPreviousData, QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import { act, renderHook, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { describe, expect, it } from "vitest"
import { keepPreviousDataWithin } from "./placeholderData"

function setup() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>
  return wrapper
}

type Entry = { key: unknown[]; identity?: number[] }

function useProbe(entry: Entry, gate: { release?: () => void; promise: Promise<void> }) {
  return useQuery({
    queryKey: entry.key,
    queryFn: async () => {
      if (gate.release) await gate.promise
      return JSON.stringify(entry.key)
    },
    placeholderData: entry.identity ? keepPreviousDataWithin(entry.key, entry.identity) : keepPreviousData
  })
}

function gate() {
  const g: { release?: () => void; promise: Promise<void> } = { promise: Promise.resolve() }
  return g
}

async function transition(first: unknown[], second: unknown[], identity?: number[]) {
  const wrapper = setup()
  const g = gate()
  const { result, rerender } = renderHook(({ entry }: { entry: Entry }) => useProbe(entry, g), { wrapper, initialProps: { entry: { key: first, identity } } })
  await waitFor(() => expect(result.current.data).toBe(JSON.stringify(first)))
  g.promise = new Promise<void>((resolve) => {
    g.release = resolve
  })
  rerender({ entry: { key: second, identity } })
  const during = result.current.data
  await act(async () => {
    g.release?.()
  })
  await waitFor(() => expect(result.current.data).toBe(JSON.stringify(second)))
  return during
}

describe("identity-aware placeholder data in queries", () => {
  it("does not show the previous chat when the chat id changes", async () => {
    expect(await transition(["chats", "1", ""], ["chats", "2", ""], [0, 1])).toBeUndefined()
  })

  it("does not show the previous Run transcript when the Run id changes, but keeps it across pages", async () => {
    expect(await transition(["admin", "transcript", "1", { page: 1, per: 50 }], ["admin", "transcript", "2", { page: 1, per: 50 }], [0, 1, 2])).toBeUndefined()
    expect(await transition(["admin", "transcript", "1", { page: 1, per: 50 }], ["admin", "transcript", "1", { page: 2, per: 50 }], [0, 1, 2])).toBe(
      JSON.stringify(["admin", "transcript", "1", { page: 1, per: 50 }])
    )
  })

  it("does not show another Job's workflows or source, but keeps them across ref/search changes", async () => {
    expect(await transition(["jobs", "1", "workflows", "?a=1"], ["jobs", "2", "workflows", "?a=1"], [0, 1])).toBeUndefined()
    expect(await transition(["jobs", "1", "source", "?ref=a"], ["jobs", "2", "source", "?ref=a"], [0, 1])).toBeUndefined()
    expect(await transition(["jobs", "1", "source", "?ref=a"], ["jobs", "1", "source", "?ref=b"], [0, 1])).toBe(
      JSON.stringify(["jobs", "1", "source", "?ref=a"])
    )
  })

  it("collection filter screens using keepPreviousData keep their previous result set", async () => {
    expect(await transition(["repositories", "q=a"], ["repositories", "q=b"])).toBe(JSON.stringify(["repositories", "q=a"]))
  })
})
