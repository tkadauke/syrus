import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { fetchEpicsGraph } from "./dashboard"

describe("fetchEpicsGraph", () => {
  afterEach(() => vi.restoreAllMocks())

  it("follows bounded pages and derives labels and URLs", async () => {
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse({
          nodes: [{ id: "epic_1", kind: "epic", title: "First", number: 1, state: "ready", epic_id: 1, is_focal: false }],
          edges: [{ from_id: "epic_1", to_id: "epic_2" }],
          pagination: { limit: 200, offset: 0, total_count: 2, has_more: true }
        })
      )
      .mockResolvedValueOnce(
        jsonResponse({
          nodes: [{ id: "epic_2", kind: "epic", title: "Second", number: 2, state: "ready", epic_id: 2, is_focal: false }],
          edges: [],
          pagination: { limit: 200, offset: 200, total_count: 2, has_more: false }
        })
      )
    const graph = await fetchEpicsGraph("?q=filter")
    expect(fetchSpy).toHaveBeenCalledTimes(2)
    expect(graph.nodes).toEqual([
      expect.objectContaining({ label: "EPIC-1 First", url: "/epics/EPIC-1" }),
      expect.objectContaining({ label: "EPIC-2 Second", url: "/epics/EPIC-2" })
    ])
    expect(graph.edges).toEqual([{ from_id: "epic_1", to_id: "epic_2" }])
  })
})
