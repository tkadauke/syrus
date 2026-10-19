import type { ReactNode } from "react"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { Badge, CapabilityBadges, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import {
  countFromInputArray,
  stringFromInput,
  ToolFailureSummaryCard,
  toolFailureCollapsedSummary,
  toolFailureDetected,
  type ToolFailureConfig
} from "../toolFailureSummaryCard"

type Obj = Record<string, unknown>
type MaterializedJob = { id: string; title: string | null }
type Requirement = { target: string; detail: string }
type Media = { ref: string; title: string; src: string | null }
type Child = {
  id: string | null
  slug: string
  title: string | null
  description: string
  state: string
  targetRepo: string | null
  provider: string | null
  dependsOn: string[]
  epicIds: string[]
  jobIds: string[]
  requirements: Requirement[]
  goalId: string | null
  planned: Obj | null
  media: Media[]
  materialized: MaterializedJob | null
}
type Outcome = {
  slug: string
  title: string | null
  description: string
  state: string
  targetRepo: string | null
  targetEpicId: string | null
  targetEpicLabel: string | null
  dependencies: string[]
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

function parse(context: ToolCardContext): Outcome | null {
  const result = object(context.parsedResult)
  if (!result) return null
  const epicInput = object(context.input?.epic) ?? {}
  const jobInputs = objects(context.input?.jobs)
  const slug = displayValue(result.slug) ?? displayValue(epicInput.slug)
  const resultState = displayValue(result.state)
  if (!slug || !resultState) return null
  const targetEpic = object(result.target_epic)
  const rootMaterialized = materializedBySlug(result)
  const resultChildren = objects(result.child_jobs)
  const sources = resultChildren.length > 0 ? resultChildren : jobInputs
  const children = sources.flatMap((resultChild, index): Child[] => {
    const childSlug = displayValue(resultChild.slug) ?? displayValue(jobInputs[index]?.slug)
    if (!childSlug) return []
    const input = jobInputs.find((job) => displayValue(job.slug) === childSlug) ?? jobInputs[index] ?? {}
    const materialized = materializedJob(resultChild) ?? rootMaterialized.get(childSlug) ?? null
    return [
      {
        id: displayValue(resultChild.id),
        slug: childSlug,
        title: displayValue(resultChild.title) ?? displayValue(input.title) ?? materialized?.title ?? null,
        description: displayValue(resultChild.description) ?? displayValue(resultChild.body) ?? displayValue(input.description) ?? "",
        state: displayValue(resultChild.state) ?? resultState,
        targetRepo: displayValue(resultChild.target_repo) ?? displayValue(input.target_repo),
        provider: displayValue(resultChild.provider_setting) ?? displayValue(resultChild.provider) ?? displayValue(input.provider),
        dependsOn: preferArray(resultChild.depends_on, input.depends_on),
        epicIds: preferArray(resultChild.depends_on_epic_ids, input.depends_on_epic_ids),
        jobIds: preferArray(resultChild.depends_on_job_ids, input.depends_on_job_ids),
        requirements: requirements(resultChild.dependency_requirements ?? input.dependency_requirements),
        goalId: goalId(resultChild.goal_provenance),
        planned: object(resultChild.planned_execution) ?? object(input.planned_execution),
        media: media(resultChild.media ?? resultChild.media_ids ?? input.media),
        materialized
      }
    ]
  })
  return {
    slug,
    title: displayValue(result.title) ?? displayValue(epicInput.title),
    description: displayValue(result.description) ?? displayValue(result.body) ?? displayValue(epicInput.description) ?? "",
    state: displayValue(context.livePendingAction?.state) ?? resultState,
    targetRepo: displayValue(result.target_repo) ?? displayValue(epicInput.target_repo),
    targetEpicId: displayValue(targetEpic?.id),
    targetEpicLabel: displayValue(targetEpic?.label),
    dependencies: [
      ...new Set([
        ...values(result.depends_on),
        ...values(result.depends_on_proposal_slugs),
        ...values(epicInput.depends_on),
        ...values(epicInput.depends_on_proposal_slugs)
      ])
    ],
    goalId: goalId(result.goal_provenance),
    children
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const outcome = parse(context)
  if (!outcome) return null
  return `Epic proposal: ${outcome.title || outcome.slug} (${outcome.state}, ${outcome.children.length} Job${outcome.children.length === 1 ? "" : "s"})`
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
      </div>
      {outcome.title ? <div className="break-words text-sm font-semibold text-text-primary">{outcome.title}</div> : null}
      <MarkdownPreview linkifyUrls maxChars={900} maxLines={4} modalLabel={`Epic description: ${outcome.title || outcome.slug}`} text={outcome.description} />
      <div className="grid min-w-0 gap-2 text-xs sm:grid-cols-2">
        {outcome.targetRepo ? (
          <Detail label="Repository">
            <Repository slug={outcome.targetRepo} />
          </Detail>
        ) : null}
        {outcome.targetEpicLabel ? (
          <Detail label="Target epic">
            {outcome.targetEpicId ? <EntityReference id={outcome.targetEpicId} kind="epic" label={outcome.targetEpicLabel} /> : outcome.targetEpicLabel}
          </Detail>
        ) : null}
        {outcome.goalId ? <Detail label="Goal provenance">Chat goal {outcome.goalId}</Detail> : null}
      </div>
      {outcome.dependencies.length ? <DependencyList label="Epic dependencies" slugs={outcome.dependencies} /> : null}
      <div>
        <SectionLabel>Dependency chain ({outcome.children.length})</SectionLabel>
        {outcome.children.length ? (
          <ol className="mt-2 space-y-2">
            {outcome.children.map((child, index) => (
              <ChildCard child={child} index={index} key={child.id ?? child.slug} />
            ))}
          </ol>
        ) : (
          <EmptyState>No child Job proposals were returned.</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

function ChildCard({ child, index }: { child: Child; index: number }) {
  return (
    <li className="min-w-0 rounded border border-border bg-surface-raised p-3">
      {index ? <div className="mb-2 text-center text-xs text-text-subtle sm:text-left">↓ next in chain</div> : null}
      <div className="flex min-w-0 flex-col gap-2 sm:flex-row sm:flex-wrap sm:items-center">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <EntityReference kind="proposal" slug={child.slug} />
          <StatePill state={child.state} />
          {child.id ? <Badge>proposal #{child.id}</Badge> : null}
        </div>
        {child.title ? <span className="min-w-0 break-words font-medium text-text-primary sm:flex-1">{child.title}</span> : null}
      </div>
      <div className="mt-2">
        <MarkdownPreview linkifyUrls maxChars={700} maxLines={3} modalLabel={`Job description: ${child.title || child.slug}`} text={child.description} />
      </div>
      <div className="mt-2 grid min-w-0 gap-2 text-xs sm:grid-cols-2">
        {child.targetRepo ? (
          <Detail label="Repository">
            <Repository slug={child.targetRepo} />
          </Detail>
        ) : null}
        {child.provider && child.provider !== "default" ? <Detail label="Provider">{child.provider}</Detail> : null}
        {child.planned ? (
          <Detail label="Planned execution">
            <CapabilityBadges capabilities={child.planned.capabilities} />
            {executionLabels(child.planned)}
          </Detail>
        ) : null}
        {child.goalId ? <Detail label="Goal provenance">Chat goal {child.goalId}</Detail> : null}
      </div>
      <ChildDependencies child={child} />
      {child.media.length ? (
        <div className="mt-2 flex max-w-full flex-wrap gap-2">
          {child.media.map((item) => (
            <MediaPreviewShell
              item={{
                title: item.title,
                subtitle: item.ref,
                src: item.src,
                fallbackLabel: "Attached media",
                actions: [{ label: "Copy reference", copyValue: item.ref }]
              }}
              key={item.ref}
              thumbnailClassName="w-40 max-w-full"
            />
          ))}
        </div>
      ) : null}
      {child.materialized ? (
        <div className="mt-2 text-xs text-text-secondary">
          Materialized as <EntityReference id={child.materialized.id} kind="job" />
          {child.materialized.title ? ` — ${child.materialized.title}` : ""}
        </div>
      ) : null}
    </li>
  )
}

function ChildDependencies({ child }: { child: Child }) {
  if (!(child.dependsOn.length || child.jobIds.length || child.epicIds.length || child.requirements.length)) return null
  return (
    <div className="mt-2 space-y-1 text-xs">
      <SectionLabel>Depends on</SectionLabel>
      <div className="flex min-w-0 flex-wrap gap-2">
        {child.dependsOn.map((slug) => (
          <EntityReference kind="proposal" key={slug} slug={slug} />
        ))}
        {child.jobIds.map((id) => (
          <EntityReference id={id} kind="job" key={`job-${id}`} />
        ))}
        {child.epicIds.map((id) => (
          <EntityReference id={id} kind="epic" key={`epic-${id}`} />
        ))}
      </div>
      {child.requirements.map((item) => (
        <div className="break-words text-text-secondary" key={`${item.target}-${item.detail}`}>
          {item.target}: {item.detail}
        </div>
      ))}
    </div>
  )
}

function DependencyList({ label, slugs }: { label: string; slugs: string[] }) {
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1 flex min-w-0 flex-wrap gap-2">
        {slugs.map((slug) =>
          /^epic:\d+$/.test(slug) ? <EntityReference id={slug.slice(5)} kind="epic" key={slug} /> : <EntityReference kind="proposal" key={slug} slug={slug} />
        )}
      </div>
    </div>
  )
}
function Detail({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="min-w-0 break-words">{children}</div>
    </div>
  )
}
function Repository({ slug }: { slug: string }) {
  return <EntityReference href={`/repositories/${encodeURIComponent(slug)}`} kind="repository" repositorySlug={slug} slug={slug} />
}
function executionLabels(value: Obj) {
  const labels = [displayValue(value.project_label), displayValue(value.target_label), displayValue(value.source)].filter((item): item is string => !!item)
  return labels.length ? <div className="mt-1 break-words text-text-secondary">{labels.join(" · ")}</div> : null
}
function requirements(value: unknown): Requirement[] {
  return objects(value).map((item) => {
    const target = displayValue(item.proposal_slug) ?? (displayValue(item.job_id) ? `JOB-${displayValue(item.job_id)}` : "Dependency")
    const mode = (displayValue(item.satisfaction_mode) ?? "success").replaceAll("_", " ")
    const stage = displayValue(item.required_deployment_stage_name)
    return { target, detail: stage ? `${mode}: ${stage}` : mode }
  })
}
function media(value: unknown): Media[] {
  return Array.isArray(value)
    ? value.flatMap((item) => {
        if (typeof item === "string" && item.trim())
          return [{ ref: item, title: item.split(":")[0].replaceAll("_", " "), src: item.startsWith("data:image/") || item.startsWith("/") ? item : null }]
        const data = object(item)
        const ref = displayValue(data?.ref) ?? displayValue(data?.id)
        return data && ref ? [{ ref, title: displayValue(data.title) ?? "Attached media", src: displayValue(data.image_url) ?? displayValue(data.src) }] : []
      })
    : []
}
function materializedBySlug(result: Obj) {
  const map = new Map<string, MaterializedJob>()
  objects(object(result.materialized)?.child_jobs).forEach((job) => {
    const slug = displayValue(job.slug) ?? displayValue(job.proposal_slug)
    const id = displayValue(job.job_id) ?? displayValue(job.id)
    if (slug && id) map.set(slug, { id, title: displayValue(job.title) ?? displayValue(job.job_title) })
  })
  return map
}
function materializedJob(value: Obj): MaterializedJob | null {
  const data = object(value.materialized) ?? value
  const id = displayValue(data.job_id)
  return id ? { id, title: displayValue(data.job_title) ?? displayValue(data.title) } : null
}
function goalId(value: unknown) {
  return displayValue(object(value)?.chat_goal_id)
}
function object(value: unknown): Obj | null {
  return Object.prototype.toString.call(value) === "[object Object]" ? (value as Obj) : null
}
function objects(value: unknown): Obj[] {
  return Array.isArray(value) ? value.map(object).filter((item): item is Obj => item != null) : []
}
function values(value: unknown): string[] {
  return Array.isArray(value) ? value.flatMap((item) => displayValue(item) ?? []) : []
}
function preferArray(primary: unknown, fallback: unknown) {
  const first = values(primary)
  return first.length ? first : values(fallback)
}

const card: ToolCardRenderer = { toolName: "propose_epic_with_jobs", collapsedSummary, renderExpanded }
export default card

export const examples: ToolCardExample[] = [
  {
    id: "planned_dependency_chain",
    label: "Planned dependency chain",
    description: "Markdown, media, placement, dependencies, and materialized Jobs.",
    input: {
      epic: {
        slug: "tool-card-polish",
        title: "Polish proposal cards",
        description: "Make the **proposal** readable.",
        target_repo: "tkadauke/syrus",
        depends_on_proposal_slugs: ["shared-markdown"]
      },
      jobs: [
        {
          slug: "render-fields",
          title: "Render every field",
          description: "Show [details](https://example.test).",
          target_repo: "tkadauke/syrus",
          media: ["chat_image:7"],
          provider: "codex",
          planned_execution: { capabilities: { os: ["linux"] }, source: "operator" }
        },
        {
          slug: "cover-results",
          title: "Cover results",
          description: "Add regression coverage.",
          depends_on: ["render-fields"],
          target_repo: "tkadauke/syrus",
          planned_execution: { capabilities: { os: ["linux"] } }
        }
      ]
    },
    parsedResult: {
      slug: "tool-card-polish",
      state: "confirmed",
      depends_on_proposal_slugs: ["shared-markdown"],
      child_jobs: [
        {
          id: 41,
          slug: "render-fields",
          state: "confirmed",
          target_repo: "tkadauke/syrus",
          provider_setting: "codex",
          job_id: 301,
          job_title: "Render every field"
        },
        {
          id: 42,
          slug: "cover-results",
          state: "confirmed",
          target_repo: "tkadauke/syrus",
          depends_on: ["render-fields"],
          job_id: 302,
          job_title: "Cover results"
        }
      ]
    }
  }
]
