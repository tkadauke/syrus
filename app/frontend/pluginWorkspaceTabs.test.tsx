import { beforeAll, describe, expect, it } from "vitest"
import { pluginWorkspaceTabComponentFor, pluginWorkspaceTabComponentKeys } from "./pluginWorkspaceTabs"
import { registerPluginContribution } from "./pluginContributionRegistry"

beforeAll(async () => {
  await import("./builtInPluginContributions")
})

describe("plugin workspace tab registry", () => {
  it("discovers installed plugin workspace tab components by component key", () => {
    expect(pluginWorkspaceTabComponentKeys()).toContain("whiteboard/WhiteboardTab")
    expect(pluginWorkspaceTabComponentFor("whiteboard/WhiteboardTab")).toBeTruthy()
    expect(pluginWorkspaceTabComponentFor("missing/Nope")).toBeNull()
  })

  it("returns null for a nullish key", () => {
    expect(pluginWorkspaceTabComponentFor(null)).toBeNull()
    expect(pluginWorkspaceTabComponentFor(undefined)).toBeNull()
  })

  it("returns a workspace tab registered at runtime", () => {
    registerPluginContribution("workspace_tab", "runtime_test", "RuntimeTab", async () => ({ default: () => null }))

    expect(pluginWorkspaceTabComponentKeys()).toContain("runtime_test/RuntimeTab")
    expect(pluginWorkspaceTabComponentFor("runtime_test/RuntimeTab")).toBeTruthy()
  })
})
