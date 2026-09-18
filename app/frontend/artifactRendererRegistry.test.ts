import { describe, expect, it, vi } from "vitest"
import type { TypedArtifact } from "./api/artifacts"
import {
  allArtifactRendererEntries,
  artifactRendererEntryFor,
  buildArtifactRendererRegistry,
  renderArtifactBody,
  renderArtifactRendererEntry,
  type ArtifactRendererEntry
} from "./artifactRendererRegistry"

function entry(overrides: Partial<ArtifactRendererEntry> = {}): ArtifactRendererEntry {
  return {
    rendererType: "some_type",
    artifactTypes: [],
    ownerType: "core",
    pluginName: null,
    displayLabel: "Some type",
    description: "A renderer",
    supportedPayloadShape: "{}",
    render: () => "rendered",
    examples: [],
    ...overrides
  }
}

const rawArtifact = (overrides: Partial<TypedArtifact> = {}): TypedArtifact => ({
  type: "some_artifact",
  title: "Some artifact",
  created_at: "2026-09-01T12:00:00Z",
  renderer_type: null,
  payload: {},
  ...overrides
})

describe("artifactRendererRegistry", () => {
  describe("core lookup", () => {
    it("resolves every core renderer_type from TypedArtifactPanel with its owner, label, and payload shape", () => {
      for (const rendererType of [ "image_diff", "before_after_visual_diff", "data_table", "before_after_diff" ]) {
        const found = artifactRendererEntryFor(rendererType)
        expect(found.rendererType).toBe(rendererType)
        expect(found.ownerType).toBe("core")
        expect(found.pluginName).toBeNull()
        expect(found.displayLabel).toBeTruthy()
        expect(found.supportedPayloadShape).toBeTruthy()
        expect(typeof found.render).toBe("function")
      }
    })

    it("includes the raw JSON fallback renderer as a first-class core entry", () => {
      const names = allArtifactRendererEntries().map((e) => e.rendererType)
      expect(names).toContain("raw_json")

      const fallback = allArtifactRendererEntries().find((e) => e.rendererType === "raw_json")!
      expect(fallback.ownerType).toBe("core")
    })

    it("gives every core entry at least one example fixture", () => {
      const coreEntries = allArtifactRendererEntries().filter((e) => e.ownerType === "core")
      expect(coreEntries.length).toBeGreaterThan(0)
      for (const coreEntry of coreEntries) {
        expect(coreEntry.examples.length).toBeGreaterThan(0)
      }
    })
  })

  describe("plugin discovery", () => {
    it("discovers the Rails plugin's erd_diagram and migration_diff renderers by directory convention", () => {
      const erd = artifactRendererEntryFor("erd_diagram")
      expect(erd.ownerType).toBe("plugin")
      expect(erd.pluginName).toBe("rails")
      expect(erd.artifactTypes).toContain("rails_schema_erd")
      expect(erd.examples.length).toBeGreaterThan(0)

      const migrationDiff = artifactRendererEntryFor("migration_diff")
      expect(migrationDiff.ownerType).toBe("plugin")
      expect(migrationDiff.pluginName).toBe("rails")
      expect(migrationDiff.artifactTypes).toContain("rails_migration_diff")
      expect(migrationDiff.examples.length).toBeGreaterThan(0)
    })

    it("includes every discovered/registered renderer_type in the full listing with unique keys", () => {
      const names = allArtifactRendererEntries().map((e) => e.rendererType)
      expect(names).toContain("erd_diagram")
      expect(names).toContain("migration_diff")
      expect(names).toContain("image_diff")
      expect(new Set(names).size).toBe(names.length)
    })
  })

  describe("buildArtifactRendererRegistry: malformed renderer entries", () => {
    it("skips a candidate missing a rendererType", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const valid = entry({ rendererType: "valid_one" })
      const malformed = { displayLabel: "No rendererType", render: () => null }

      const result = buildArtifactRendererRegistry([ valid, malformed ])

      expect(result).toEqual([ valid ])
      expect(warn).toHaveBeenCalledWith(expect.stringContaining("malformed"))
      warn.mockRestore()
    })

    it("skips a candidate missing a render function", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const malformed = { rendererType: "no_render" }

      const result = buildArtifactRendererRegistry([ malformed ])

      expect(result).toEqual([])
      expect(warn).toHaveBeenCalled()
      warn.mockRestore()
    })

    it("skips null/undefined candidates without throwing", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      expect(() => buildArtifactRendererRegistry([ null, undefined, entry() ])).not.toThrow()
      warn.mockRestore()
    })
  })

  describe("buildArtifactRendererRegistry: duplicate renderer handling", () => {
    it("keeps the first registration and skips a later duplicate rendererType, logging a warning", () => {
      const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
      const first = entry({ rendererType: "dup", displayLabel: "First" })
      const second = entry({ rendererType: "dup", displayLabel: "Second", ownerType: "plugin", pluginName: "some_plugin" })

      const result = buildArtifactRendererRegistry([ first, second ])

      expect(result).toEqual([ first ])
      expect(warn).toHaveBeenCalledWith(expect.stringContaining("Duplicate renderer_type \"dup\""))
      warn.mockRestore()
    })

    it("does not treat two different rendererTypes as duplicates", () => {
      const a = entry({ rendererType: "a" })
      const b = entry({ rendererType: "b" })

      const result = buildArtifactRendererRegistry([ a, b ])

      expect(result).toEqual(expect.arrayContaining([ a, b ]))
      expect(result.length).toBe(2)
    })
  })

  describe("fallback behavior", () => {
    it("falls back to the raw JSON renderer for a null renderer_type", () => {
      const found = artifactRendererEntryFor(null)
      expect(found.rendererType).toBe("raw_json")
    })

    it("falls back to the raw JSON renderer for an unregistered renderer_type", () => {
      const found = artifactRendererEntryFor("totally_unknown_renderer_type")
      expect(found.rendererType).toBe("raw_json")
    })

    it("renderArtifactBody renders the raw JSON fallback for an artifact with no renderer_type", () => {
      const rendered = renderArtifactBody(rawArtifact({ renderer_type: null, payload: { a: 1 } }))
      expect(rendered).toBeTruthy()
    })

    it("falls back to raw JSON when a renderer's render() throws, instead of crashing the panel", () => {
      const error = vi.spyOn(console, "error").mockImplementation(() => {})
      const broken = entry({ rendererType: "broken_one", render: () => { throw new Error("boom") } })

      const result = renderArtifactRendererEntry(broken, rawArtifact())

      expect(result).toBeTruthy()
      expect(error).toHaveBeenCalled()
      error.mockRestore()
    })

    it("returns null (not a second throw) when the raw JSON fallback entry itself throws", () => {
      const error = vi.spyOn(console, "error").mockImplementation(() => {})
      const brokenFallback = entry({ rendererType: "raw_json", render: () => { throw new Error("boom") } })

      expect(() => renderArtifactRendererEntry(brokenFallback, rawArtifact())).not.toThrow()
      expect(renderArtifactRendererEntry(brokenFallback, rawArtifact())).toBeNull()
      error.mockRestore()
    })

    it("renderArtifactBody never throws for a live registry entry, even given a malformed payload", () => {
      for (const artifactEntry of allArtifactRendererEntries()) {
        for (const example of artifactEntry.examples) {
          expect(() => renderArtifactBody(example.artifact)).not.toThrow()
        }
      }
    })
  })
})
