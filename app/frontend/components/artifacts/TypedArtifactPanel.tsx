import type { TypedArtifact, ImageDiffPayload, BeforeAfterVisualDiffPayload, BeforeAfterVisualImage } from "../../api/artifacts"
import { useT } from "../../hooks/useT"
import { pluginArtifactBodyFor } from "../../pluginArtifactRenderers"

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

// Exported so other tabs (e.g. ArtifactsTab) render the same set of
// renderer_type -> component mappings instead of duplicating this switch.
export function ArtifactBody({ artifact }: { artifact: TypedArtifact }) {
  const pluginBody = pluginArtifactBodyFor(artifact)
  if (pluginBody) return pluginBody

  switch (artifact.renderer_type) {
    case "image_diff":
      return <ImageDiffBody payload={artifact.payload as ImageDiffPayload} title={artifact.title} />
    case "before_after_visual_diff":
      return <BeforeAfterVisualDiffBody payload={artifact.payload as BeforeAfterVisualDiffPayload} />
    case "data_table":
      return <DataTableBody payload={artifact.payload as Record<string, unknown>} />
    case "before_after_diff":
      return <BeforeAfterDiffBody payload={artifact.payload as Record<string, unknown>} />
    default:
      return <RawArtifactBody payload={artifact.payload} />
  }
}

function DataTableBody({ payload }: { payload: Record<string, unknown> }) {
  const headers = Array.isArray(payload.headers) ? payload.headers as string[] : []
  const rows = Array.isArray(payload.rows) ? payload.rows as unknown[][] : []

  if (headers.length === 0 && rows.length === 0) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-xs">
        {headers.length > 0 ? (
          <thead>
            <tr>
              {headers.map((h, i) => (
                <th className="border border-gray-200 bg-gray-100 px-2 py-1.5 text-left font-semibold text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={i}>{String(h)}</th>
              ))}
            </tr>
          </thead>
        ) : null}
        <tbody>
          {rows.map((row, ri) => (
            <tr className="even:bg-gray-50 dark:even:bg-gray-800/50" key={ri}>
              {(Array.isArray(row) ? row : [row]).map((cell, ci) => (
                <td className="border border-gray-200 px-2 py-1 text-gray-800 dark:border-gray-700 dark:text-gray-200" key={ci}>{String(cell ?? "")}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function BeforeAfterDiffBody({ payload }: { payload: Record<string, unknown> }) {
  const { t } = useT("jobs")
  const before = typeof payload.before === "string" ? payload.before : null
  const after = typeof payload.after === "string" ? payload.after : null

  if (before === null && after === null) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="grid gap-3 lg:grid-cols-2">
      <div>
        <p className="mb-1 text-xs font-medium text-gray-500 dark:text-gray-400">{t("artifact_diff_before")}</p>
        <pre className="overflow-x-auto rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">{before ?? "(empty)"}</pre>
      </div>
      <div>
        <p className="mb-1 text-xs font-medium text-gray-500 dark:text-gray-400">{t("artifact_diff_after")}</p>
        <pre className="overflow-x-auto rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">{after ?? "(empty)"}</pre>
      </div>
    </div>
  )
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
