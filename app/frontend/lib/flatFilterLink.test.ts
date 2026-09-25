import { describe, expect, it, vi } from "vitest"
import { buildFlatFilterLink, decodeFlatFilterChips } from "./flatFilterLink"

function encode(value: unknown) {
  return btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

describe("flat FilterBar links", () => {
  it("decodes simple top-level chips for flat-query pages", () => {
    expect(decodeFlatFilterChips(encode({ and: [{ field: "hours", op: "is", value: "24" }] }))).toEqual([
      { field: "hours", value: "24" }
    ])
  })

  it("rejects complex chip groups instead of partially applying them", () => {
    expect(decodeFlatFilterChips(encode({ and: [{ not: { field: "surface", op: "is", value: "chat" } }] }))).toBeNull()
    expect(decodeFlatFilterChips(encode({ and: [{ or: [{ field: "surface", op: "is", value: "chat" }] }] }))).toBeNull()
  })

  it("preserves existing flat params when FilterBar emits unsupported NOT or OR filters", () => {
    const link = buildFlatFilterLink(["surface", "tool_name"], vi.fn())

    expect(link("/admin/mcp_tool_usage", "?surface=chat&tool_name=repo_info", {
      q: encode({ and: [{ not: { field: "surface", op: "is", value: "chat" } }] }),
      page: null,
      surface: null,
      tool_name: null
    })).toBe("/admin/mcp_tool_usage?surface=chat&tool_name=repo_info")
  })
})
