import type { TypedArtifact } from "../../api/artifacts"
import { renderArtifactBody } from "../../artifactRendererRegistry"

// Renders all typed artifacts stored on a workflow. Dispatches to the
// appropriate renderer via the artifact renderer registry (see
// artifactRendererRegistry.ts), falling back to a JSON code block for any
// renderer_type nothing registers.
export function TypedArtifactPanel({ artifacts }: { artifacts: TypedArtifact[] }) {
  if (artifacts.length === 0) return null

  return (
    <div className="min-w-0 space-y-4">
      {artifacts.map((artifact, index) => (
        <ArtifactCard key={artifactKey(artifact, index)} artifact={artifact} />
      ))}
    </div>
  )
}

// Same `type` can now appear more than once (one entry per review round —
// see App::JobDetailPayload#typed_artifacts_json), so `type` alone is no
// longer a safe React key.
function artifactKey(artifact: TypedArtifact, index: number) {
  return [ artifact.type, artifact.workflow_id ?? "x", artifact.run_id ?? "x", artifact.created_at ?? index ].join("-")
}

function ArtifactCard({ artifact }: { artifact: TypedArtifact }) {
  return (
    <div className="min-w-0 overflow-hidden rounded border border-gray-200 bg-white">
      <div className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1 border-b border-gray-100 px-4 py-2">
        <span className="min-w-0 break-words font-semibold text-gray-800">{artifact.title}</span>
        <span className="min-w-0 break-all text-xs text-gray-400">{artifact.type}</span>
      </div>
      <div className="overflow-x-auto p-4">
        <ArtifactBody artifact={artifact} />
      </div>
    </div>
  )
}

// Exported so other tabs (e.g. ArtifactsTab) render the same set of
// renderer_type -> component mappings instead of duplicating this switch.
export function ArtifactBody({ artifact }: { artifact: TypedArtifact }) {
  return <>{renderArtifactBody(artifact)}</>
}
