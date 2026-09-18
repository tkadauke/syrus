import { describe, expect, it } from "vitest"
import { discoveredArtifactRendererEntries } from "./pluginArtifactRenderers"

describe("pluginArtifactRenderers", () => {
  it("discovers plugin-registered renderers by directory convention, without any core import of that plugin", () => {
    // erd_diagram.tsx and migration_diff.tsx live entirely under
    // plugins/rails/app/frontend/artifact_renderers/ -- this file (and the
    // rest of core) never imports that directory directly.
    const rendererTypes = discoveredArtifactRendererEntries.map((entry) => entry.definition.rendererType)
    expect(rendererTypes).toContain("erd_diagram")
    expect(rendererTypes).toContain("migration_diff")
  })

  it("attributes every discovered entry to the plugin whose directory it was found under", () => {
    const erd = discoveredArtifactRendererEntries.find((entry) => entry.definition.rendererType === "erd_diagram")
    expect(erd?.owner).toEqual({ ownerType: "plugin", pluginName: "rails" })

    const migrationDiff = discoveredArtifactRendererEntries.find((entry) => entry.definition.rendererType === "migration_diff")
    expect(migrationDiff?.owner).toEqual({ ownerType: "plugin", pluginName: "rails" })
  })

  it("gives every discovered renderer a usable definition and example fixtures", () => {
    for (const discovered of discoveredArtifactRendererEntries) {
      expect(typeof discovered.definition.render).toBe("function")
      expect(discovered.definition.rendererType.length).toBeGreaterThan(0)

      const ids = discovered.examples.map((example) => example.id)
      expect(new Set(ids).size).toBe(ids.length)
      for (const id of ids) expect(id).toBeTruthy()
    }
  })
})
