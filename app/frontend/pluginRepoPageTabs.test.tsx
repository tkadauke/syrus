import { describe, expect, it } from "vitest"
import { pluginRepoComponentFor, pluginRepoComponentKeys } from "./pluginRepoPageTabs"

describe("plugin repo page tab registry", () => {
  it("discovers installed plugin repo tab route components by component key", () => {
    expect(pluginRepoComponentKeys()).toEqual(expect.any(Array))
    expect(pluginRepoComponentFor("missing/Nope")).toBeNull()
    expect(pluginRepoComponentFor(null)).toBeNull()
    expect(pluginRepoComponentFor(undefined)).toBeNull()
  })
})
