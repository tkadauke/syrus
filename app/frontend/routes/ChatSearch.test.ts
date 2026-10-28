import { describe, expect, it } from "vitest"
import { chatSearchFilterLink, filterFromSearch } from "./ChatSearch"

function encodedFilter(op: string, value: string | string[]) {
  const json = JSON.stringify({ and: [{ field: "coworker_id", op, value }] })
  return btoa(json).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
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
})
