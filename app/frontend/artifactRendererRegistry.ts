// Unified artifact renderer registry -- the single contract describing how
// every typed_artifacts `renderer_type` (see TypedArtifact in
// api/artifacts.ts) is presented: core renderers, plugin-owned renderers,
// and the raw-JSON fallback. Mirrors toolPresentationRegistry.ts's role for
// chat tool cards -- this is the identity/metadata layer a future Artifact
// Renderer Catalog page renders from, composing existing rendering
// implementations (coreArtifactRenderers.tsx's bodies, plugin-owned
// components discovered via pluginArtifactRenderers.tsx) rather than
// duplicating them.
import type { ReactNode } from "react"
import type { TypedArtifact } from "./api/artifacts"
import { coreArtifactRendererEntries, RAW_JSON_RENDERER_TYPE } from "./components/artifacts/coreArtifactRenderers"
import { discoveredArtifactRendererEntries, type ArtifactRendererExample } from "./pluginArtifactRenderers"

export type { ArtifactRendererExample }

export type ArtifactRendererEntry = {
  rendererType: string
  artifactTypes: string[]
  ownerType: "core" | "plugin"
  pluginName: string | null
  displayLabel: string
  description: string
  supportedPayloadShape: string
  render: (artifact: TypedArtifact) => ReactNode
  examples: ArtifactRendererExample[]
}

function isValidEntry(candidate: unknown): candidate is ArtifactRendererEntry {
  if (!candidate || typeof candidate !== "object") return false
  const entry = candidate as Partial<ArtifactRendererEntry>
  return typeof entry.rendererType === "string" && entry.rendererType.length > 0 && typeof entry.render === "function"
}

function describeCandidate(candidate: unknown): string {
  try {
    return JSON.stringify(candidate)
  } catch {
    return String(candidate)
  }
}

// Merges raw candidate entries (core + discovered plugin entries, or -- in
// tests -- hand-built fixtures) into the final registry: skips malformed
// entries (missing a usable rendererType/render) and, on a rendererType
// collision, keeps the first registration and skips the rest. Exported
// (rather than only used internally) so malformed-entry and
// duplicate-renderer behavior can be exercised directly with synthetic
// candidates, without depending on real plugin files on disk.
export function buildArtifactRendererRegistry(candidates: unknown[]): ArtifactRendererEntry[] {
  const byRendererType = new Map<string, ArtifactRendererEntry>()

  for (const candidate of candidates) {
    if (!isValidEntry(candidate)) {
      console.warn(`[artifactRendererRegistry] Skipping malformed renderer entry: ${describeCandidate(candidate)}`)
      continue
    }

    if (byRendererType.has(candidate.rendererType)) {
      const owner = candidate.ownerType === "plugin" ? `plugin "${candidate.pluginName}"` : "core"
      console.warn(`[artifactRendererRegistry] Duplicate renderer_type "${candidate.rendererType}" registered by ${owner}; keeping the first registration.`)
      continue
    }

    byRendererType.set(candidate.rendererType, candidate)
  }

  return Array.from(byRendererType.values())
}

function pluginCandidates(): ArtifactRendererEntry[] {
  return discoveredArtifactRendererEntries.map((discovered) => ({
    ...discovered.definition,
    ownerType: discovered.owner.ownerType,
    pluginName: discovered.owner.pluginName,
    examples: discovered.examples
  }))
}

function coreCandidates(): ArtifactRendererEntry[] {
  return coreArtifactRendererEntries.map((entry) => ({ ...entry, ownerType: "core" as const, pluginName: null }))
}

let cachedEntries: ArtifactRendererEntry[] | null = null

function registryEntries(): ArtifactRendererEntry[] {
  if (!cachedEntries) cachedEntries = buildArtifactRendererRegistry([ ...coreCandidates(), ...pluginCandidates() ])
  return cachedEntries
}

// Every entry the registry currently knows about -- core, plugin-owned, and
// the raw JSON fallback. Intended for the Artifact Renderer Catalog (a
// later Job); exported here so that page never has to re-implement
// discovery.
export function allArtifactRendererEntries(): ArtifactRendererEntry[] {
  return registryEntries()
}

function rawJsonFallbackEntry(): ArtifactRendererEntry {
  const found = registryEntries().find((entry) => entry.rendererType === RAW_JSON_RENDERER_TYPE)
  if (!found) throw new Error("[artifactRendererRegistry] raw JSON fallback entry is missing from the registry")
  return found
}

// Resolves a renderer_type to its registry entry. A null/unregistered
// renderer_type -- unknown to core and to every installed plugin -- always
// falls back to the raw JSON entry, so callers never need a null check to
// keep rendering.
export function artifactRendererEntryFor(rendererType: string | null | undefined): ArtifactRendererEntry {
  if (rendererType) {
    const found = registryEntries().find((entry) => entry.rendererType === rendererType)
    if (found) return found
  }
  return rawJsonFallbackEntry()
}

// Renders one artifact through a specific registry entry, falling back to
// raw JSON when the entry's render() throws (a malformed real-world payload
// its own guard didn't anticipate) -- unknown/malformed artifacts must
// always degrade safely instead of taking down the whole panel. Takes the
// entry explicitly (mirroring pluginToolCards.tsx's renderToolCard(renderer,
// context)) so this fallback behavior is directly testable with a synthetic
// entry, without needing to inject it into the live registry.
export function renderArtifactRendererEntry(entry: ArtifactRendererEntry, artifact: TypedArtifact): ReactNode {
  try {
    return entry.render(artifact)
  } catch (error) {
    console.error(`[artifactRendererRegistry] renderer "${entry.rendererType}" threw for artifact type "${artifact.type}"`, error)
    return entry.rendererType === RAW_JSON_RENDERER_TYPE ? null : rawJsonFallbackEntry().render(artifact)
  }
}

// Renders one typed artifact through the registry, the single dispatch
// point TypedArtifactPanel's ArtifactBody delegates to.
export function renderArtifactBody(artifact: TypedArtifact): ReactNode {
  return renderArtifactRendererEntry(artifactRendererEntryFor(artifact.renderer_type), artifact)
}
