import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { fetchDashboardControls, fetchEpicsGraph } from "./dashboard"

describe("fetchEpicsGraph", () => {
  afterEach(() => vi.restoreAllMocks())

  it("loads every page and derives labels and URLs client-side", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const offset = new URL(String(input), "http://syrus.test").searchParams.get("offset")
      return Promise.resolve(
        jsonResponse({
          nodes: [
            {
              id: offset === "0" ? "epic_1" : "epic_2",
              kind: "epic",
              number: offset === "0" ? 1 : 2,
              title: offset === "0" ? "First" : "Second",
              state: "ready",
              epic_id: offset === "0" ? 1 : 2,
              is_focal: false
            }
          ],
          edges: [{ from_id: "epic_1", to_id: "epic_2" }],
          pagination: { limit: 1, offset: Number(offset), total_count: 2, has_more: offset === "0" }
        })
      )
    })

    const graph = await fetchEpicsGraph("?q=roadmap")

    expect(graph.nodes.map((node) => [node.label, node.url])).toEqual([
      ["EPIC-1 First", "/epics/EPIC-1"],
      ["EPIC-2 Second", "/epics/EPIC-2"]
    ])
    expect(graph.edges).toEqual([{ from_id: "epic_1", to_id: "epic_2" }])
    expect(fetchSpy).toHaveBeenCalledTimes(2)
  })
})

describe("fetchDashboardControls", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("scopes the request to the active smart folder so folder-specific required columns are returned", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({ controls: {} })))

    await fetchDashboardControls("job", { smartFolderId: "20" })
    await fetchDashboardControls("job")

    expect(String(fetchSpy.mock.calls[0][0])).toBe("/api/v1/app/dashboard/controls?subject=job&smart_folder_id=20")
    expect(String(fetchSpy.mock.calls[1][0])).toBe("/api/v1/app/dashboard/controls?subject=job")
  })
})
