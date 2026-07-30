import type { TypedArtifact, SchemaErdPayload, MigrationDiffPayload } from "../../api/jobs"
import { ErdDiagramRenderer } from "./ErdDiagramRenderer"
import { MigrationDiffRenderer } from "./MigrationDiffRenderer"

// Renders all typed artifacts stored on a workflow. Dispatches to the
// appropriate renderer component based on renderer_type. Unknown renderer
// types fall back to a JSON code block.
export function TypedArtifactPanel({ artifacts }: { artifacts: TypedArtifact[] }) {
  if (artifacts.length === 0) return null

  return (
    <div className="space-y-4">
      {artifacts.map((artifact) => (
        <ArtifactCard key={artifact.type} artifact={artifact} />
      ))}
    </div>
  )
}

function ArtifactCard({ artifact }: { artifact: TypedArtifact }) {
  return (
    <div className="rounded border border-gray-200 bg-white">
      <div className="border-b border-gray-100 px-4 py-2">
        <span className="font-semibold text-gray-800">{artifact.title}</span>
        <span className="ml-2 text-xs text-gray-400">{artifact.type}</span>
      </div>
      <div className="p-4">
        <ArtifactBody artifact={artifact} />
      </div>
    </div>
  )
}

function ArtifactBody({ artifact }: { artifact: TypedArtifact }) {
  if (artifact.renderer_type === "erd_diagram") {
    return <ErdDiagramRenderer payload={artifact.payload as SchemaErdPayload} />
  }
  if (artifact.renderer_type === "migration_diff") {
    return <MigrationDiffRenderer payload={artifact.payload as MigrationDiffPayload} />
  }
  return (
    <pre className="overflow-x-auto rounded bg-gray-50 p-3 text-xs text-gray-700">
      {JSON.stringify(artifact.payload, null, 2)}
    </pre>
  )
}
