import { describe, expect, it } from "vitest"
import { pluginWorkspaceTabComponentFor, pluginWorkspaceTabComponentKeys } from "./pluginWorkspaceTabs"

describe("plugin workspace tab registry", () => {
  it("discovers installed plugin workspace tab components by component key", () => {
    expect(pluginWorkspaceTabComponentKeys()).toContain("syrus_dev/WorkspaceTabDemo")
    expect(pluginWorkspaceTabComponentFor("syrus_dev/WorkspaceTabDemo")).toBeTruthy()
    expect(pluginWorkspaceTabComponentFor("missing/Nope")).toBeNull()
  })

  it("returns null for a nullish key", () => {
    expect(pluginWorkspaceTabComponentFor(null)).toBeNull()
    expect(pluginWorkspaceTabComponentFor(undefined)).toBeNull()
  })
})
