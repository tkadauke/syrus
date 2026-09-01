import type { ReactNode } from "react"
import type { MigrationDiffPayload, SchemaErdPayload, TypedArtifact } from "@app/api/artifacts"
import { ErdDiagramRenderer } from "./ErdDiagramRenderer"
import { MigrationDiffRenderer } from "./MigrationDiffRenderer"

export { ErdDiagramRenderer, MigrationDiffRenderer }

export type RailsArtifactRenderer = {
  rendererType: NonNullable<TypedArtifact["renderer_type"]>
  render: (artifact: TypedArtifact) => ReactNode
}

export const railsArtifactRenderers: RailsArtifactRenderer[] = [
  {
    rendererType: "erd_diagram",
    render: (artifact) => <ErdDiagramRenderer payload={artifact.payload as SchemaErdPayload} />
  },
  {
    rendererType: "migration_diff",
    render: (artifact) => <MigrationDiffRenderer payload={artifact.payload as MigrationDiffPayload} />
  }
]
