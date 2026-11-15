import { describe, expect, it } from "vitest"
import { chatSearchFilterLink, filterFromSearch } from "./ChatSearch"

function encodedFilter(op: string, value: string | string[]) {
  const json = JSON.stringify({ and: [{ field: "coworker_id", op, value }] })
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function encodedChips(and: Array<{ field: string; op: string; value: string | string[] }>) {
  return btoa(JSON.stringify({ and })).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

describe("chat search coworker filter links", () => {
  it.each([
    ["is", "7"],
    ["is_not", "7"],
    ["is_one_of", ["7", "syrus"]],
    ["is_none_of", ["7", "syrus"]]
  ])("preserves %s and its values", (op, value) => {
    const link = chatSearchFilterLink("/chats/search", "?q=calendar", { q: encodedFilter(op as string, value as string | string[]) })
    const search = link.slice(link.indexOf("?"))

    expect(new URLSearchParams(search).get("coworker_op")).toBe(op)
    expect(filterFromSearch(search)).toEqual({ and: [{ field: "coworker_id", op, value }] })
  })

  it("removes the last plugin filter and its operator", () => {
    const link = chatSearchFilterLink(
      "/chats/search",
      "?coworker_id=7&coworker_op=is_not",
      { q: null },
      ["coworker_id"]
    )

    expect(link).toBe("/chats/search")
  })

  it("removes a stale plugin filter while retaining core and other plugin filters", () => {
    const q = encodedChips([
      { field: "q", op: "contains", value: "calendar" },
      { field: "team_id", op: "is_one_of", value: ["2", "3"] }
    ])
    const link = chatSearchFilterLink(
      "/chats/search",
      "?q=old&coworker_id=7&coworker_op=is_not&team_id=1&team_op=is",
      { q },
      ["coworker_id", "team_id"]
    )
    const params = new URL(link, "https://example.test").searchParams

    expect(params.get("q")).toBe("calendar")
    expect(params.has("coworker_id")).toBe(false)
    expect(params.has("coworker_op")).toBe(false)
    expect(params.get("team_id")).toBe("2,3")
    expect(params.get("team_op")).toBe("is_one_of")
  })
})
