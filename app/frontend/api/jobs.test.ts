import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { fetchPickerJobs, fetchPreview, fetchPreviewLogs, mergePreviewLogs, previewLogCursor, type PreviewLogsPayload } from "./jobs"

describe("jobs API", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("asks for the preview without its static project list when polling", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ preview: null })))

    await fetchPreview("/api/v1/app/jobs/1/preview", { includeProjects: false })
    await fetchPreview("/api/v1/app/jobs/1/preview")

    expect(fetchMock.mock.calls.map(([input]) => String(input))).toEqual(["/api/v1/app/jobs/1/preview?projects=0", "/api/v1/app/jobs/1/preview"])
  })

  it("sends the per-file size cursor as since and merges incremental log chunks", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ logs: [] })))
    const env = { id: 1 } as PreviewLogsPayload["preview"]
    const first: PreviewLogsPayload = { preview: env, logs: [{ path: "log/a.log", content: "a\nb", missing: false, size: 4 }] }

    expect(previewLogCursor(first)).toEqual({ "log/a.log": 4 })
    await fetchPreviewLogs("/api/v1/app/jobs/1/preview/logs", previewLogCursor(first))
    expect(String(fetchMock.mock.calls[0][0])).toBe(`/api/v1/app/jobs/1/preview/logs?since=${encodeURIComponent('{"log/a.log":4}')}`)

    const merged = mergePreviewLogs(first, { preview: env, logs: [{ path: "log/a.log", content: "\nc", missing: false, size: 6, incremental: true }] })
    expect(merged.logs[0]).toMatchObject({ content: "a\nb\nc", size: 6, incremental: false })

    const replaced = mergePreviewLogs(merged, { preview: env, logs: [{ path: "log/a.log", content: "fresh", missing: false, size: 5 }] })
    expect(replaced.logs[0].content).toBe("fresh")
  })

  it("includes active work in picker job searches", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ count: 0, jobs: [] }))

    await fetchPickerJobs({ state: "running", repo: "acme/widgets", limit: 25 })

    expect(fetchMock).toHaveBeenCalledWith(
      "/api/v1/app/jobs?state=running&repo=acme%2Fwidgets&fields=picker&include_active_work=true&limit=25",
      expect.anything()
    )
  })

  it("sends picker search and pull request filters to the server", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ count: 0, jobs: [] }))

    await fetchPickerJobs({ q: "older job", withPr: true })

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/jobs?q=older+job&with_pr=true&fields=picker&include_active_work=true&limit=50", expect.anything())
  })
})
