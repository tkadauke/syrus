import type { ReactNode } from "react"
import type { TypedArtifact } from "./api/artifacts"
import { railsArtifactRenderers } from "@plugins/rails/app/frontend/components/artifacts"

export type PluginArtifactRenderer = {
  rendererType: NonNullable<TypedArtifact["renderer_type"]>
  render: (artifact: TypedArtifact) => ReactNode
}

const pluginArtifactRenderers: PluginArtifactRenderer[] = [
  ...railsArtifactRenderers
]

export function pluginArtifactBodyFor(artifact: TypedArtifact) {
  if (!artifact.renderer_type) return null

  const renderer = pluginArtifactRenderers.find((candidate) => candidate.rendererType === artifact.renderer_type)
  return renderer?.render(artifact) ?? null
}
