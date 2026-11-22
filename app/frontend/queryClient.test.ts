import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("./api/browserErrors", async (importOriginal) => {
  const original = await importOriginal<typeof import("./api/browserErrors")>()
  return { ...original, recordBrowserError: vi.fn().mockResolvedValue({ id: 1, fingerprint: "fp", occurrence_count: 1 }) }
})

import { recordBrowserError } from "./api/browserErrors"
import { reportHandledError } from "./lib/handledErrorReporting"
import { createQueryClient } from "./queryClient"

const mockRecordBrowserError = vi.mocked(recordBrowserError)

afterEach(() => {
  vi.useRealTimers()
  mockRecordBrowserError.mockClear()
})

describe("createQueryClient", () => {
  it("uses network-friendly defaults for queries", () => {
    expect(createQueryClient().getDefaultOptions().queries).toMatchObject({
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: 1
    })
  })

  it("reports terminal query and mutation failures with central fallback context", async () => {
    vi.useFakeTimers()
    const client = createQueryClient()

    await expect(
      client.fetchQuery({ queryKey: ["private", "query", "values"], queryFn: () => Promise.reject(new Error("query failed")), retry: false })
    ).rejects.toThrow("query failed")
    const mutation = client.getMutationCache().build(client, { mutationFn: () => Promise.reject(new Error("mutation failed")) })
    await expect(mutation.execute(undefined)).rejects.toThrow("mutation failed")
    await vi.runAllTimersAsync()

    expect(mockRecordBrowserError).toHaveBeenCalledTimes(2)
    expect(mockRecordBrowserError.mock.calls.map(([payload]) => payload.metadata.handled_error)).toEqual([
      { surface: "react_query", operation: "query", stage: "terminal", recoverability: "unknown" },
      { surface: "react_query", operation: "mutation", stage: "terminal", recoverability: "unknown" }
    ])
    expect(JSON.stringify(mockRecordBrowserError.mock.calls)).not.toContain("private")
  })

  it("does not duplicate a terminal failure explicitly reported by its surface", async () => {
    vi.useFakeTimers()
    const client = createQueryClient()
    const error = new Error("save failed")

    const mutation = client.getMutationCache().build(client, { mutationFn: () => Promise.reject(error) })
    await expect(mutation.execute(undefined)).rejects.toBe(error)
    reportHandledError(error, { surface: "job_editor", operation: "save", stage: "request", recoverability: "retryable" })
    await vi.runAllTimersAsync()

    expect(mockRecordBrowserError).toHaveBeenCalledTimes(1)
    expect(mockRecordBrowserError.mock.calls[0][0].metadata.handled_error).toMatchObject({ surface: "job_editor", stage: "request" })
  })
})
