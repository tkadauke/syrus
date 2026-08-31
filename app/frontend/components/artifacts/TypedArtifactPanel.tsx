import type { TypedArtifact, SchemaErdPayload, MigrationDiffPayload, ImageDiffPayload, BeforeAfterVisualDiffPayload, BeforeAfterVisualImage } from "../../api/artifacts"
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
  if (artifact.renderer_type === "image_diff") {
    return <ImageDiffBody payload={artifact.payload as ImageDiffPayload} title={artifact.title} />
  }
  if (artifact.renderer_type === "before_after_visual_diff") {
    return <BeforeAfterVisualDiffBody payload={artifact.payload as BeforeAfterVisualDiffPayload} />
  }
  return <RawArtifactBody payload={artifact.payload} />
}

function ImageDiffBody({ payload, title }: { payload: ImageDiffPayload; title: string }) {
  if (!payload.image_url) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <a href={payload.image_url} target="_blank" rel="noreferrer">
      <img src={payload.image_url} alt={title} className="max-w-full rounded border border-gray-200" />
    </a>
  )
}

function BeforeAfterVisualDiffBody({ payload }: { payload: BeforeAfterVisualDiffPayload }) {
  const pairs = Array.isArray(payload.pairs) ? payload.pairs : []
  if (pairs.length === 0) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="space-y-4">
      {pairs.map((pair, index) => (
        <div className="space-y-2" key={`${pair.title || "visual"}-${index}`}>
          <div className="text-xs font-semibold text-gray-700">{pair.title || `Screenshot ${index + 1}`}</div>
          <div className="grid gap-3 md:grid-cols-2">
            <VisualPane label="Merge-base / before" image={pair.before} />
            <VisualPane label="PR / after" image={pair.after} />
          </div>
        </div>
      ))}
    </div>
  )
}

function VisualPane({ label, image }: { label: string; image: BeforeAfterVisualImage }) {
  if (!image?.image_url) return null

  return (
    <div>
      <div className="mb-1 text-xs font-medium text-gray-500">{label}</div>
      <a href={image.image_url} target="_blank" rel="noreferrer">
        <img src={image.image_url} alt={`${label}: ${image.title || "screenshot"}`} className="max-w-full rounded border border-gray-200" />
      </a>
    </div>
  )
}

function RawArtifactBody({ payload }: { payload: unknown }) {
  return (
    <pre className="overflow-x-auto rounded bg-gray-50 p-3 text-xs text-gray-700">
      {JSON.stringify(payload, null, 2)}
    </pre>
  )
}
