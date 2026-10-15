import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { fetchPickerJobs } from "./jobs"

describe("jobs API", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("includes active work in picker job searches", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ count: 0, jobs: [] }))

    await fetchPickerJobs({ state: "running", repo: "acme/widgets", limit: 25 })

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/jobs?state=running&repo=acme%2Fwidgets&include_active_work=true&limit=25", expect.anything())
  })

  it("sends picker search and pull request filters to the server", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ count: 0, jobs: [] }))

    await fetchPickerJobs({ q: "older job", withPr: true })

    expect(fetchMock).toHaveBeenCalledWith("/api/v1/app/jobs?q=older+job&with_pr=true&include_active_work=true&limit=50", expect.anything())
  })
})
