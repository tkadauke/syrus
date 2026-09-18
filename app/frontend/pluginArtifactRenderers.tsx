import type { ReactNode } from "react"
import type { TypedArtifact } from "./api/artifacts"

// Extension point for custom typed-artifact renderers (the artifact
// renderer registry contract -- see artifactRendererRegistry.ts).
//
// A renderer upgrades how one `renderer_type` (see TypedArtifact) displays
// inside TypedArtifactPanel/ArtifactBody, in place of the raw-JSON
// fallback. Plugin-owned renderers register next to the renderer_type they
// own, under `<plugin>/app/frontend/artifact_renderers/*.tsx` -- this file
// discovers them by directory convention (mirrors pluginToolCards.tsx), so
// adding or changing a plugin's renderer never requires editing this file,
// artifactRendererRegistry.ts, or any other core file. Core-owned renderer
// types (image_diff, before_after_visual_diff, data_table,
// before_after_diff, and the raw JSON fallback) are registered directly in
// components/artifacts/coreArtifactRenderers.tsx instead of being
// discovered this way, since they ship with core rather than a plugin.
//
// A renderer_type with no registered entry anywhere (core or plugin) keeps
// rendering through the raw JSON fallback.

export type ArtifactRendererExample = {
  // Stable identifier within this renderer's example set -- a React key
  // and a future catalog deep-link target, so it must survive reordering
  // the `examples` array. Convention: lower_snake_case, e.g. "two_tables".
  id: string
  label: string
  // Longer note for a human reviewer on what this fixture demonstrates or
  // why it's shaped the way it is (e.g. "malformed: missing headers/rows").
  // Omit when the label already says it all.
  description?: string
  // A ready-to-render TypedArtifact fixture -- handed straight to
  // renderArtifactBody/ArtifactBody, the same shape a live artifact has.
  artifact: TypedArtifact
}

// What a renderer module (core or plugin) declares about the renderer_type
// it owns, before owner attribution is attached at discovery/registration
// time (see ArtifactRendererEntry in artifactRendererRegistry.ts).
export type ArtifactRendererDefinition = {
  // Canonical `renderer_type` this entry renders (see TypedArtifact) --
  // what ArtifactBody dispatches on.
  rendererType: string
  // Known/canonical `type` values (the free-form identifier an agent or
  // step passes to submit_artifact/set_typed_artifact!) that resolve to
  // this renderer_type. Some renderer types are intentionally generic --
  // data_table and before_after_diff render whatever agent-chosen `type` a
  // step submits, matched purely by renderer_type -- so an empty array is a
  // valid "any type" declaration, not a missing one.
  artifactTypes: string[]
  displayLabel: string
  description: string
  // Short human-readable note on the payload shape this renderer expects,
  // for catalog/documentation display -- not runtime-validated (the actual
  // TypeScript payload types live in api/artifacts.ts).
  supportedPayloadShape: string
  render: (artifact: TypedArtifact) => ReactNode
}

export type ArtifactRendererOwner = { ownerType: "core" | "plugin"; pluginName: string | null }

export type DiscoveredArtifactRendererEntry = {
  definition: ArtifactRendererDefinition
  owner: ArtifactRendererOwner
  examples: ArtifactRendererExample[]
  path: string
}

type ArtifactRendererModule = { default?: ArtifactRendererDefinition; examples?: ArtifactRendererExample[] }

const PLUGIN_RENDERER_PATH_PATTERN = /\/plugins\/([^/]+)\/app\/frontend\/artifact_renderers\//

const rendererModules = import.meta.glob<ArtifactRendererModule>(
  [ "../../plugins/*/app/frontend/artifact_renderers/*.tsx", "!../../plugins/*/app/frontend/artifact_renderers/*.test.tsx" ],
  { eager: true }
)

function isValidDefinition(definition: ArtifactRendererDefinition | undefined): definition is ArtifactRendererDefinition {
  return !!definition && typeof definition.rendererType === "string" && definition.rendererType.length > 0 && typeof definition.render === "function"
}

function ownerForRendererPath(path: string): ArtifactRendererOwner {
  const pluginMatch = path.match(PLUGIN_RENDERER_PATH_PATTERN)
  return pluginMatch ? { ownerType: "plugin", pluginName: pluginMatch[1] } : { ownerType: "core", pluginName: null }
}

export const discoveredArtifactRendererEntries: DiscoveredArtifactRendererEntry[] = Object.entries(rendererModules).flatMap(([ path, mod ]) => {
  const definition = mod.default
  if (!isValidDefinition(definition)) {
    console.warn(`[pluginArtifactRenderers] Skipping ${path}: default export is not a valid ArtifactRendererDefinition`)
    return []
  }

  return [{ definition, owner: ownerForRendererPath(path), examples: mod.examples ?? [], path }]
})
