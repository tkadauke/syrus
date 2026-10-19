import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MediaPreviewShell, type MediaPreviewAction } from "../mediaPreviewShell"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, StatePill } from "../toolCardUi"

type ArtifactRow = {
  type: string
  title: string | null
  contentType: string | null
  byteSize: number | null
  runId: string | null
  stepId: string | null
  iteration: string | null
  imageUrl: string | null
  source: string | null
  capturedAt: string | null
  page: string | null
  viewport: string | null
}
type ArtifactList = { workflowId: string | null; jobId: string | null; rows: ArtifactRow[] }

function parseArtifactRow(value: unknown): ArtifactRow | null {
  if (!isPlainObject(value)) return null
  const type = displayValue(value.type)
  if (!type) return null
  return {
    type,
    title: displayValue(value.title),
    contentType: displayValue(value.content_type),
    byteSize: numberValue(value.byte_size),
    runId: displayValue(value.run_id),
    stepId: displayValue(value.step_id),
    iteration: displayValue(value.iteration),
    imageUrl: displayValue(value.image_url),
    source: displayValue(value.source),
    capturedAt: displayValue(value.captured_at),
    page: displayValue(value.page),
    viewport: displayValue(value.viewport)
  }
}

function artifactList(context: ToolCardContext): ArtifactList | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.artifacts)) return null
  return {
    workflowId: displayValue(context.input?.workflow_id) ?? displayValue(parsed.workflow_id),
    jobId: displayValue(parsed.job_id),
    rows: parsed.artifacts.flatMap((item) => {
      const row = parseArtifactRow(item)
      return row ? [row] : []
    })
  }
}

function formatBytes(bytes: number | null): string | null {
  if (bytes == null) return null
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function artifactKey(row: ArtifactRow, index: number) {
  return [row.type, row.runId, row.stepId, row.iteration, row.imageUrl, index].join(":")
}

export function listArtifactsSummary(context: ToolCardContext) {
  if (context.resultError) return "Failed to list artifacts"
  if (context.parsedResult == null && !context.resultBody) return "Listing artifacts…"
  const list = artifactList(context)
  if (!list) return null
  return list.rows.length === 0 ? "No artifacts" : `${list.rows.length} artifact${list.rows.length === 1 ? "" : "s"}`
}

function ArtifactReferences({ row, workflowId, jobId }: { row: ArtifactRow; workflowId: string | null; jobId: string | null }) {
  return (
    <div className="flex min-w-0 flex-wrap gap-1">
      {row.runId ? (
        <Badge>
          <EntityReference id={row.runId} jobId={jobId} kind="run" workflowId={workflowId} />
        </Badge>
      ) : null}
      {row.stepId ? (
        <Badge>
          <EntityReference
            href={jobId && workflowId ? `/jobs/${jobId}?tab=workflows#workflow-${workflowId}` : null}
            id={`STEP-${row.stepId}`}
            kind="artifact"
          />
        </Badge>
      ) : null}
      {!row.runId && !row.stepId ? <span className="text-gray-400">—</span> : null}
    </div>
  )
}

function ArtifactPreview({ row }: { row: ArtifactRow }) {
  if (!row.imageUrl) return <span className="text-gray-400">—</span>
  const actions: MediaPreviewAction[] = [
    { label: "Open", href: row.imageUrl },
    { label: "Download", href: row.imageUrl, download: true }
  ]
  return (
    <MediaPreviewShell
      item={{
        title: row.title ?? row.type,
        subtitle: row.contentType,
        src: row.imageUrl,
        alt: row.title ?? row.type,
        badge: "image",
        actions,
        meta: [
          { label: "Type", value: row.type },
          { label: "Source", value: row.source },
          { label: "Captured", value: row.capturedAt },
          { label: "Page", value: row.page },
          { label: "Viewport", value: row.viewport }
        ]
      }}
      modalLabel={row.title ?? row.type}
      thumbnailClassName="w-32 min-w-24"
    />
  )
}

function Value({ children }: { children: string | null }) {
  return children ? <span className="break-words text-gray-700 dark:text-gray-300">{children}</span> : <span className="text-gray-400">—</span>
}

function ArtifactDetails({ row }: { row: ArtifactRow }) {
  const details = [
    ["Content type", row.contentType],
    ["Size", formatBytes(row.byteSize)],
    ["Iteration", row.iteration],
    ["Source", row.source],
    ["Captured", row.capturedAt],
    ["Page", row.page],
    ["Viewport", row.viewport]
  ]
  return (
    <dl className="grid min-w-0 grid-cols-2 gap-x-3 gap-y-1">
      {details.map(([label, value]) => (
        <div className="min-w-0" key={label}>
          <dt className="text-2xs font-semibold uppercase text-gray-500">{label}</dt>
          <dd>
            <Value>{value}</Value>
          </dd>
        </div>
      ))}
    </dl>
  )
}

export function ArtifactListCard({ list }: { list: ArtifactList }) {
  if (list.rows.length === 0) return <EmptyState>No artifacts recorded on this Workflow.</EmptyState>
  return (
    <div className="mt-1 rounded border border-gray-200 dark:border-gray-700">
      <div className="divide-y divide-gray-100 sm:hidden dark:divide-gray-800">
        {list.rows.map((row, index) => (
          <article className="min-w-0 space-y-3 p-3" key={artifactKey(row, index)}>
            <div className="flex min-w-0 items-start justify-between gap-2">
              <EntityReference id={row.type} kind="artifact" />
              <ArtifactReferences jobId={list.jobId} row={row} workflowId={list.workflowId} />
            </div>
            <Value>{row.title}</Value>
            <ArtifactPreview row={row} />
            <ArtifactDetails row={row} />
          </article>
        ))}
      </div>
      <div className="hidden sm:block">
        <table className="w-full table-fixed text-left text-xs">
          <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
            <tr>
              {["Artifact", "Preview", "Details", "Run / Step"].map((label) => (
                <th className="px-2 py-1 font-semibold" key={label} scope="col">
                  {label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
            {list.rows.map((row, index) => (
              <tr className="align-top" key={artifactKey(row, index)}>
                <td className="min-w-0 px-2 py-2">
                  <EntityReference id={row.type} kind="artifact" />
                  <div className="mt-1">
                    <Value>{row.title}</Value>
                  </div>
                </td>
                <td className="px-2 py-2">
                  <ArtifactPreview row={row} />
                </td>
                <td className="min-w-0 px-2 py-2">
                  <ArtifactDetails row={row} />
                </td>
                <td className="min-w-0 px-2 py-2">
                  <ArtifactReferences jobId={list.jobId} row={row} workflowId={list.workflowId} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

export function renderArtifactList(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state="failed" />
          <span className="font-semibold">List artifacts</span>
        </div>
        <div className="break-words text-red-700 dark:text-red-300">{context.resultBody || "The artifact list could not be loaded."}</div>
      </CardShell>
    )
  if (context.parsedResult == null && !context.resultBody)
    return (
      <CardShell>
        <div className="flex min-h-8 items-center gap-2">
          <StatePill state="pending" />
          <span>Waiting for artifacts…</span>
        </div>
      </CardShell>
    )
  const list = artifactList(context)
  if (!list) return null
  return (
    <CardShell>
      {list.workflowId ? (
        <div className="flex min-h-8 items-center gap-2 text-xs">
          <span className="text-gray-500">Workflow</span>
          <EntityReference id={list.workflowId} jobId={list.jobId} kind="workflow" />
        </div>
      ) : null}
      <ArtifactListCard list={list} />
    </CardShell>
  )
}

const listArtifactsToolCard: ToolCardRenderer = { toolName: "list_artifacts", collapsedSummary: listArtifactsSummary, renderExpanded: renderArtifactList }
export default listArtifactsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "visual_and_structured_artifacts",
    label: "Visual and structured artifacts",
    input: { workflow_id: 28622 },
    parsedResult: {
      workflow_id: 28622,
      job_id: 7706,
      artifacts: [
        {
          type: "visual_review_screenshot_1",
          title: "Homepage after fix",
          content_type: "image/png",
          byte_size: 204800,
          run_id: 144524,
          step_id: 223959,
          iteration: 1,
          image_url: "/api/v1/app/workflows/28622/visual_artifact?type=visual_review_screenshot_1",
          source: "playwright",
          captured_at: "2026-10-18T12:30:00Z",
          page: "/",
          viewport: "1280x720"
        },
        { type: "rails_schema_erd", title: "Schema ERD", content_type: "application/json" }
      ]
    }
  },
  { id: "empty", label: "No artifacts", input: { workflow_id: 28622 }, parsedResult: { workflow_id: 28622, artifacts: [] } },
  { id: "failure", label: "Failed request", input: { workflow_id: 28622 }, resultBody: "Workflow was not found.", resultError: true }
]
