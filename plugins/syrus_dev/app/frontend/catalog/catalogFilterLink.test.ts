import { describe, expect, it } from "vitest"
import { encodeFilterTree } from "@app/components/filterBar/helpers"
import { buildCatalogFilterLink, catalogFilterTreeFromSearch, catalogFiltersFromSearch, decodeFilterChips } from "./catalogFilterLink"

const FIELDS = [ "name", "owner", "status" ] as const
const TEXT_FIELDS: readonly (typeof FIELDS)[number][] = [ "name" ]

describe("catalogFiltersFromSearch", () => {
  it("extracts only the declared fields, trimmed, from the query string", () => {
    const filters = catalogFiltersFromSearch(FIELDS, "?name=%20Bash%20&owner=core&unrelated=ignored")
    expect(filters).toEqual({ name: "Bash", owner: "core" })
  })

  it("omits a field whose value is blank", () => {
    const filters = catalogFiltersFromSearch(FIELDS, "?name=&owner=core")
    expect(filters).toEqual({ owner: "core" })
  })
})

describe("catalogFilterTreeFromSearch", () => {
  it("renders declared text fields as 'contains' chips and everything else as 'is' chips", () => {
    const tree = catalogFilterTreeFromSearch(FIELDS, TEXT_FIELDS, "?name=Bash&owner=core")
    expect(tree.and).toEqual([
      { field: "name", op: "contains", value: "Bash" },
      { field: "owner", op: "is", value: "core" }
    ])
  })

  it("produces an empty tree when no declared field is present", () => {
    const tree = catalogFilterTreeFromSearch(FIELDS, TEXT_FIELDS, "?unrelated=ignored")
    expect(tree.and).toEqual([])
  })
})

describe("decodeFilterChips", () => {
  it("round-trips chips encoded by FilterBar's own encodeFilterTree", () => {
    const encoded = encodeFilterTree({ and: [ { field: "owner", op: "is", value: "plugin" }, { field: "name", op: "contains", value: "erd" } ] })
    expect(decodeFilterChips(encoded)).toEqual([
      { field: "owner", value: "plugin" },
      { field: "name", value: "erd" }
    ])
  })

  it("returns an empty array for malformed input instead of throwing", () => {
    expect(decodeFilterChips("not-valid-base64!!")).toEqual([])
  })
})

describe("buildCatalogFilterLink", () => {
  const link = buildCatalogFilterLink(FIELDS)

  it("applies a plain, non-declared-field param update onto the existing search string", () => {
    const result = link("/admin/things", "?other=keep", { page: "2" })
    expect(result).toBe("/admin/things?other=keep&page=2")
  })

  it("deletes a non-declared-field param when its update value is null or empty", () => {
    const result = link("/admin/things", "?other=keep&page=2", { page: null })
    expect(result).toBe("/admin/things?other=keep")
  })

  // FilterBar always sends a `q` key on every link it builds (either an
  // encoded chip tree or null -- see FilterBar.tsx's own updates object), so
  // "q" absent entirely never happens through the real chip UI. This
  // constructor still defaults consistently for a direct caller that omits
  // it: no `q` reads the same as an explicit `q: null` (see the "declared
  // fields" test below) rather than leaving stale declared-field params
  // behind from a previous chip encoding.
  it("clears every declared field when 'q' is omitted entirely, not just when it is explicitly null", () => {
    const result = link("/admin/things", "?name=Bash&owner=core", { page: "2" })
    const params = new URLSearchParams(result.split("?")[1])
    expect(params.get("name")).toBeNull()
    expect(params.get("owner")).toBeNull()
    expect(params.get("page")).toBe("2")
  })

  it("decodes an encoded FilterBar chip tree ('q') into flat declared-field params, replacing prior ones", () => {
    const encoded = encodeFilterTree({ and: [ { field: "owner", op: "is", value: "core" } ] })
    const result = link("/admin/things", "?name=Bash&status=stale", { q: encoded })
    const params = new URLSearchParams(result.split("?")[1])
    expect(params.get("owner")).toBe("core")
    expect(params.get("name")).toBeNull()
    expect(params.get("status")).toBeNull()
  })

  it("clears every declared field when 'q' is explicitly cleared", () => {
    const result = link("/admin/things", "?name=Bash&owner=core&other=keep", { q: null })
    const params = new URLSearchParams(result.split("?")[1])
    expect(params.get("name")).toBeNull()
    expect(params.get("owner")).toBeNull()
    expect(params.get("other")).toBe("keep")
  })

  it("returns the bare path when the resulting search string is empty", () => {
    const result = link("/admin/things", "?name=Bash", { name: null })
    expect(result).toBe("/admin/things")
  })
})
