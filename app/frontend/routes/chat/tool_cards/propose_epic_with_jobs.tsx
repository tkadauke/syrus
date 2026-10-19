import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { workerCapabilitiesText } from "@app/lib/workerCapabilities"
import { MarkdownPreview } from "../toolCardMarkdown"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import {
  countFromInputArray,
  stringFromInput,
  ToolFailureSummaryCard,
  toolFailureCollapsedSummary,
  toolFailureDetected,
  type ToolFailureConfig
} from "../toolFailureSummaryCard"

type Execution = { project: string | null; target: string | null; capabilities: string | null; source: string | null }
type MaterializedJob = { id: string; title: string | null; state: string | null }
type Media = { ref: string; title: string; subtitle: string | null; src: string | null; badge: string }
type Child = {
  id: string | null
  slug: string
  title: string | null
  description: string
  state: string
  repo: string | null
  provider: string | null
  proposals: string[]
  epics: string[]
  jobs: string[]
  requirements: string[]
  execution: Execution | null
  goalId: string | null
  media: Media[]
  materialized: MaterializedJob | null
}
type Outcome = {
  id: string | null
  slug: string
  title: string | null
  description: string
  state: string
  targetEpicId: string | null
  targetEpicLabel: string | null
  proposals: string[]
  epics: string[]
  jobs: string[]
  goalId: string | null
  children: Child[]
}

const failureConfig: ToolFailureConfig = {
  title: "Epic with Jobs proposal",
  attempted: (context) => {
    const title = stringFromInput(context, ["title", "epic_title", "name"])
    const count = countFromInputArray(context, "jobs")
    return `${title ? `Propose epic: ${title}` : "Propose epic"}${count == null ? "" : ` with ${count} Job${count === 1 ? "" : "s"}`}`
  },
  retrySafety: "caution",
  recovery: "Check whether any epic or child Job proposals were created before retrying."
}

function strings(value: unknown) {
  if (!Array.isArray(value)) return []
  return [...new Set(value.flatMap((item) => displayValue(item) || []))]
}

function execution(value: unknown): Execution | null {
  if (!object(value)) return null
  const result = {
    project: displayValue(value.project_label),
    target: displayValue(value.target_label),
    capabilities: workerCapabilitiesText(value.capabilities) || null,
    source: displayValue(value.source)
  }
  return Object.values(result).some(Boolean) ? result : null
}

function goalId(value: unknown) {
  return object(value) ? displayValue(value.chat_goal_id) : null
}

function materialized(value: unknown): MaterializedJob | null {
  if (!object(value) || displayValue(value.kind) !== "job") return null
  const id = displayValue(value.job_id)
  return id ? { id, title: displayValue(value.job_title), state: displayValue(value.job_state) } : null
}

function requirements(value: unknown) {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!object(item)) return []
    const jobId = displayValue(item.job_id) || displayValue(item.depends_on_job_id)
    const target = displayValue(item.proposal_slug) || displayValue(item.depends_on) || displayValue(item.slug) || (jobId ? `JOB-${jobId}` : null)
    const mode = displayValue(item.satisfaction_mode)?.replace(/_/g, " ")
    const stage = displayValue(item.required_deployment_stage_name)
    const detail = [mode, stage ? `stage: ${stage}` : null].filter(Boolean).join(" · ")
    return target || detail ? [[target, detail].filter(Boolean).join(" — ")] : []
  })
}

function media(value: unknown, previewsValue: unknown): Media[] {
  const previews = Array.isArray(previewsValue) ? previewsValue.filter(object) : []
  const byRef = new Map(
    previews.flatMap((preview) => {
      const ref = displayValue(preview.id)
      return ref ? [[ref, preview] as const] : []
    })
  )
  return strings(value).map((ref) => {
    const preview = byRef.get(ref)
    const badge = displayValue(preview?.kind) || ref.split(":")[0]?.replace(/_/g, " ") || "media"
    const path = displayValue(preview?.file_path) || displayValue(preview?.image_url)
    return {
      ref,
      title: displayValue(preview?.filename) || displayValue(preview?.name) || ref,
      subtitle: displayValue(preview?.content_type) || displayValue(preview?.created_at),
      src: path && (path.startsWith("/") || path.startsWith("data:image/")) ? path : null,
      badge
    }
  })
}

function parseChildren(value: unknown): Child[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!object(item)) return []
    const slug = displayValue(item.slug),
      state = displayValue(item.state)
    if (!slug || !state) return []
    return [
      {
        id: displayValue(item.id),
        slug,
        title: displayValue(item.title),
        description: displayValue(item.description) || displayValue(item.body) || "",
        state,
        repo: displayValue(item.target_repo) || displayValue(item.repository),
        provider: displayValue(item.provider) || displayValue(item.provider_setting),
        proposals: strings(item.depends_on),
        epics: strings(item.depends_on_epic_ids),
        jobs: strings(item.depends_on_job_ids),
        requirements: requirements(item.dependency_requirements),
        execution: execution(item.planned_execution),
        goalId: goalId(item.goal_provenance),
        media: media(item.media ?? item.media_ids, item.media_previews),
        materialized: materialized(item.materialized)
      }
    ]
  })
}

function parse(context: ToolCardContext): Outcome | null {
  const value = context.parsedResult
  if (!object(value)) return null
  const slug = displayValue(value.slug),
    state = displayValue(value.state)
  if (!slug || !state) return null
  const dependencies = strings(value.depends_on)
  return {
    id: displayValue(value.id),
    slug,
    title: displayValue(value.title),
    description: displayValue(value.description) || displayValue(value.body) || "",
    state,
    targetEpicId: object(value.target_epic) ? displayValue(value.target_epic.id) : null,
    targetEpicLabel: object(value.target_epic) ? displayValue(value.target_epic.label) : null,
    proposals: [...new Set([...strings(value.depends_on_proposal_slugs), ...dependencies.filter((token) => !/^epic:\d+$/.test(token))])],
    epics: dependencies.flatMap((token) => token.match(/^epic:(\d+)$/)?.[1] || []),
    jobs: strings(value.depends_on_job_ids),
    goalId: goalId(value.goal_provenance),
    children: parseChildren(value.child_jobs)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const outcome = parse(context)
  if (!outcome) return null
  return `Epic proposal: ${outcome.title || outcome.slug} (${outcome.state}, ${outcome.children.length} Job${outcome.children.length === 1 ? "" : "s"})`
}

function Dependencies({ proposals, epics, jobs }: { proposals: string[]; epics: string[]; jobs: string[] }) {
  if (proposals.length + epics.length + jobs.length === 0) return <span className="text-text-subtle">None</span>
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-1.5">
      {proposals.map((slug) => (
        <EntityReference kind="proposal" key={`p-${slug}`} slug={slug} />
      ))}
      {epics.map((id) => (
        <EntityReference id={id} kind="epic" key={`e-${id}`} />
      ))}
      {jobs.map((id) => (
        <EntityReference id={id} kind="job" key={`j-${id}`} />
      ))}
    </div>
  )
}

function ChildCard({ child, index }: { child: Child; index: number }) {
  const executionText =
    child.execution &&
    [
      child.execution.project && `project: ${child.execution.project}`,
      child.execution.target && `target: ${child.execution.target}`,
      child.execution.capabilities,
      child.execution.source && `source: ${child.execution.source}`
    ]
      .filter(Boolean)
      .join(" · ")
  return (
    <li className="min-w-0 rounded border border-border bg-surface-raised p-3">
      <div className="flex min-w-0 flex-col gap-2 sm:flex-row sm:items-start">
        <span className="shrink-0 text-xs font-semibold text-text-subtle">{index + 1}</span>
        <div className="min-w-0 flex-1 space-y-2">
          <div className="flex min-w-0 flex-wrap items-center gap-2">
            <EntityReference kind="proposal" slug={child.slug} />
            <StatePill state={child.state} />
            {child.id ? <span className="text-2xs text-text-subtle">Proposal #{child.id}</span> : null}
          </div>
          {child.title ? <div className="break-words text-sm font-semibold text-text-primary">{child.title}</div> : null}
          <MarkdownPreview
            emptyLabel="No description provided."
            linkifyUrls
            maxChars={720}
            modalLabel={`${child.title || child.slug} description`}
            text={child.description}
          />
          <dl className="grid min-w-0 gap-2 text-xs sm:grid-cols-2">
            {child.repo ? (
              <div className="min-w-0">
                <SectionLabel>Repository</SectionLabel>
                <EntityReference kind="repository" repositorySlug={child.repo} slug={child.repo} />
              </div>
            ) : null}
            {child.provider && child.provider !== "default" ? (
              <div>
                <SectionLabel>Provider</SectionLabel>
                <span>{child.provider}</span>
              </div>
            ) : null}
            {executionText ? (
              <div className="min-w-0 sm:col-span-2">
                <SectionLabel>Planned execution</SectionLabel>
                <span>{executionText}</span>
              </div>
            ) : null}
            {child.goalId ? (
              <div>
                <SectionLabel>Goal provenance</SectionLabel>
                <span>Goal #{child.goalId}</span>
              </div>
            ) : null}
            <div className="min-w-0 sm:col-span-2">
              <SectionLabel>Depends on</SectionLabel>
              <Dependencies epics={child.epics} jobs={child.jobs} proposals={child.proposals} />
            </div>
            {child.requirements.length ? (
              <div className="min-w-0 sm:col-span-2">
                <SectionLabel>Dependency requirements</SectionLabel>
                <div className="flex flex-wrap gap-1">
                  {child.requirements.map((label) => (
                    <Badge key={label}>{label}</Badge>
                  ))}
                </div>
              </div>
            ) : null}
          </dl>
          {child.media.length ? (
            <div>
              <SectionLabel>Media</SectionLabel>
              <div className="mt-1 grid grid-cols-2 gap-2 sm:grid-cols-3">
                {child.media.map((item) => (
                  <MediaPreviewShell
                    item={{
                      title: item.title,
                      subtitle: item.subtitle,
                      src: item.src,
                      alt: item.title,
                      badge: item.badge,
                      fallbackLabel: item.badge,
                      actions: [{ label: "Copy ID", copyValue: item.ref }]
                    }}
                    key={item.ref}
                    thumbnailClassName="w-full"
                  />
                ))}
              </div>
            </div>
          ) : null}
          {child.materialized ? (
            <div className="flex flex-wrap items-center gap-2 text-xs">
              <span>Materialized as</span>
              <EntityReference id={child.materialized.id} kind="job" label={child.materialized.title || undefined} />
              {child.materialized.state ? <StatePill state={child.materialized.state} /> : null}
            </div>
          ) : null}
        </div>
      </div>
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const outcome = parse(context)
  if (!outcome) return null
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>Epic</Badge>
        <StatePill state={outcome.state} />
        <EntityReference kind="proposal" slug={outcome.slug} />
        {outcome.id ? <span className="text-2xs text-text-subtle">Proposal #{outcome.id}</span> : null}
      </div>
      {outcome.title ? <div className="break-words text-sm font-semibold text-text-primary">{outcome.title}</div> : null}
      <MarkdownPreview
        emptyLabel="No Epic description provided."
        linkifyUrls
        maxChars={720}
        modalLabel={`${outcome.title || outcome.slug} description`}
        text={outcome.description}
      />
      <dl className="grid min-w-0 gap-2 text-xs sm:grid-cols-2">
        {outcome.targetEpicLabel || outcome.targetEpicId ? (
          <div>
            <SectionLabel>Target epic</SectionLabel>
            {outcome.targetEpicId ? (
              <EntityReference id={outcome.targetEpicId} kind="epic" label={outcome.targetEpicLabel} slug={outcome.targetEpicLabel} />
            ) : (
              outcome.targetEpicLabel
            )}
          </div>
        ) : null}
        {outcome.goalId ? (
          <div>
            <SectionLabel>Goal provenance</SectionLabel>
            <span>Goal #{outcome.goalId}</span>
          </div>
        ) : null}
        <div className="min-w-0 sm:col-span-2">
          <SectionLabel>Epic dependencies</SectionLabel>
          <Dependencies epics={outcome.epics} jobs={outcome.jobs} proposals={outcome.proposals} />
        </div>
      </dl>
      <div>
        <SectionLabel>Dependency chain ({outcome.children.length})</SectionLabel>
        {outcome.children.length ? (
          <ol className="mt-1 space-y-2">
            {outcome.children.map((child, index) => (
              <ChildCard child={child} index={index} key={child.id || child.slug} />
            ))}
          </ol>
        ) : (
          <EmptyState>No child Job proposals returned.</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

const card: ToolCardRenderer = { toolName: "propose_epic_with_jobs", collapsedSummary, renderExpanded }
export default card

export const examples: ToolCardExample[] = [
  {
    id: "dependency_chain",
    label: "Epic with linked child dependency chain",
    sourceType: "generic",
    parsedResult: {
      id: 42,
      slug: "release-readiness",
      title: "Release readiness",
      description: "Coordinate the **release** work.",
      state: "proposed",
      depends_on: ["epic:7"],
      depends_on_job_ids: [6],
      child_jobs: [
        {
          id: 43,
          slug: "prepare-release",
          title: "Prepare release",
          description: "Prepare artifacts for JOB-12.",
          state: "proposed",
          target_repo: "acme/widgets",
          depends_on_job_ids: [12],
          planned_execution: { capabilities: { os: ["linux"] } }
        },
        {
          id: 44,
          slug: "publish-release",
          title: "Publish release",
          description: "Publish after preparation.",
          state: "proposed",
          target_repo: "acme/widgets",
          depends_on: ["prepare-release"],
          media: ["chat_image:9"],
          media_previews: [
            {
              id: "chat_image:9",
              kind: "chat_image",
              filename: "release.png",
              content_type: "image/png",
              file_path: "/api/v1/app/chats/1/media/chat_images/9/file"
            }
          ],
          planned_execution: { capabilities: { os: ["linux"] } }
        }
      ]
    }
  }
]

function object(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
