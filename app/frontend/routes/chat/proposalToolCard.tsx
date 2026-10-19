import { type ReactNode } from "react"
import type { ToolCardContext } from "../../pluginToolCards"
import { workerCapabilityEntries } from "../../lib/workerCapabilities"
import { MarkdownPreview } from "./toolCardMarkdown"
import { MediaPreviewShell } from "./mediaPreviewShell"
import { Badge, CardShell, displayValue, EntityReference, SectionLabel, StatePill } from "./toolCardUi"

// Shared parsing/rendering for the core proposal tools (propose_job,
// propose_epic, list_proposals, delete_proposal) — the pending-action tool-card work.
// Lives outside tool_cards/ for the same reason as toolCardUi.tsx: the
// pluginToolCards.tsx directory glob treats every non-test .tsx under
// tool_cards/ as a card module and would warn about a missing default
// export. propose_epic_with_jobs has its own, differently-shaped payload
// (no title, a child_jobs list of proposals rather than a materialized
// result) and is handled by its own tool_cards/propose_epic_with_jobs.tsx.
export type MaterializedOutcome =
  | { kind: "job"; jobId: string; jobTitle: string | null; jobState: string | null }
  | { kind: "epic"; epicId: string; childJobs: MaterializedChildJob[] }
  | { kind: "rejected"; reason: string }
  | null

type MaterializedChildJob = { jobId: string; title: string | null }

export type ProposalOutcome = {
  slug: string
  title: string | null
  body: string
  kind: string
  state: string
  labels: string[]
  repository: string | null
  dependencies: string[]
  jobDependencyIds: string[]
  epicDependencyIds: string[]
  dependencyRequirements: DependencyRequirement[]
  targetEpicId: string | null
  targetEpicLabel: string | null
  investigation: boolean
  initialJobState: string | null
  providerSetting: string | null
  plannedExecutionText: string | null
  capabilitiesText: string | null
  goalProvenanceText: string | null
  media: ProposalMedia[]
  materialized: MaterializedOutcome
}

type DependencyRequirement = { target: string; mode: string; stage: string | null }
type ProposalMedia = {
  reference: string
  title: string
  detail: string
  kind: "image" | "snapshot" | "preview"
  src: string | null
  previewKind: "image" | "frame" | "metadata"
}

function plannedExecutionCapabilitiesText(plannedExecution: unknown) {
  if (!isPlainObject(plannedExecution)) return null
  const entries = workerCapabilityEntries(plannedExecution.capabilities)
  if (entries.length === 0) return null

  const byDimension = new Map<string, string[]>()
  entries.forEach((entry) => {
    byDimension.set(entry.dimension, [...(byDimension.get(entry.dimension) || []), entry.value])
  })
  return Array.from(byDimension.entries())
    .map(([dimension, values]) => `${dimension}: ${values.join(", ")}`)
    .join(" · ")
}

function parseMaterialized(value: unknown): MaterializedOutcome {
  if (!isPlainObject(value)) return null
  const kind = displayValue(value.kind)

  if (kind === "job") {
    const jobId = displayValue(value.job_id)
    return jobId ? { kind: "job", jobId, jobTitle: displayValue(value.job_title), jobState: displayValue(value.job_state) } : null
  }

  if (kind === "epic") {
    const epicId = displayValue(value.epic_id)
    if (!epicId) return null
    return { kind: "epic", epicId, childJobs: materializedChildJobs(value.child_jobs) }
  }

  if (kind === "rejected") {
    const reason = displayValue(value.reason)
    return reason ? { kind: "rejected", reason } : null
  }

  return null
}

function materializedChildJobs(value: unknown): MaterializedChildJob[] {
  if (!Array.isArray(value)) return []

  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const jobId = displayValue(item.job_id)
    if (!jobId) return []
    return [{ jobId, title: displayValue(item.title) }]
  })
}

function stringList(value: unknown): string[] {
  return Array.isArray(value) ? value.map(displayValue).filter((item): item is string => Boolean(item)) : []
}

function repositoryLabel(value: unknown): string | null {
  if (!isPlainObject(value)) return displayValue(value)
  return displayValue(value.slug) || displayValue(value.full_name) || displayValue(value.name)
}

function dependencyRequirements(value: unknown): DependencyRequirement[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const jobId = displayValue(item.job_id ?? item.depends_on_job_id)
    const slug = displayValue(item.proposal_slug ?? item.depends_on ?? item.slug)
    const target = jobId ? `JOB-${jobId}` : slug
    if (!target) return []
    return [{ target, mode: displayValue(item.satisfaction_mode) || "success", stage: displayValue(item.required_deployment_stage_name) }]
  })
}

function objectSummary(value: unknown): string | null {
  if (!isPlainObject(value) || Object.keys(value).length === 0) return null
  return Object.entries(value)
    .map(([key, entry]) => `${key.replace(/_/g, " ")}: ${isPlainObject(entry) ? JSON.stringify(entry) : (displayValue(entry) ?? "—")}`)
    .join(" · ")
}

function proposalMedia(references: string[], presentation?: ToolCardContext["presentation"]): ProposalMedia[] {
  return references.map((reference) => {
    const [kind, rawId] = reference.split(":", 2)
    const id = Number(rawId)

    if (kind === "chat_image") {
      const image = presentation?.chatMedia?.chat_images.find((candidate) => candidate.id === id)
      const derivedSrc =
        presentation?.chatId && Number.isFinite(id) ? `/api/v1/app/chats/${encodeURIComponent(String(presentation.chatId))}/media/chat_images/${id}/file` : null
      return {
        reference,
        title: image?.title || image?.filename || reference,
        detail: image?.content_type || "Chat image",
        kind: "image",
        src: image?.image_url || image?.file_path || derivedSrc,
        previewKind: image?.image_url || image?.file_path || derivedSrc ? "image" : "metadata"
      }
    }

    if (kind === "snapshot") {
      const snapshot = presentation?.chatMedia?.snapshots.find((candidate) => candidate.id === id)
      return {
        reference,
        title: snapshot?.name || reference,
        detail: snapshot ? `${snapshot.element_count} whiteboard element${snapshot.element_count === 1 ? "" : "s"}` : "Whiteboard snapshot",
        kind: "snapshot",
        src: null,
        previewKind: "metadata"
      }
    }

    if (kind === "preview_panel_version") {
      const match = presentation?.previewPanels
        ?.flatMap((panel) => panel.versions.map((version) => ({ panel, version })))
        .find(({ version }) => version.id === id)
      const src = match ? `${match.panel.app_file_base_path}/${encodeURIComponent(match.version.entry_path)}?v=${match.version.id}&raw=1` : null
      return {
        reference,
        title: match?.panel.title || reference,
        detail: match ? `Preview · ${match.version.entry_path}` : "Preview mockup",
        kind: "preview",
        src,
        previewKind: match?.version.entry_viewer_kind === "image" ? "image" : src ? "frame" : "metadata"
      }
    }

    return { reference, title: reference, detail: "Media attachment", kind: "image", src: null, previewKind: "metadata" }
  })
}

export function parseProposalOutcome(
  value: unknown,
  rawInput?: Record<string, unknown>,
  presentation?: ToolCardContext["presentation"]
): ProposalOutcome | null {
  if (!isPlainObject(value)) return null
  const input = rawInput ?? {}
  const slug = displayValue(value.slug)
  const state = displayValue(value.state)
  if (!slug || !state) return null

  return {
    slug,
    title: displayValue(value.title),
    body: displayValue(value.body) || displayValue(input.description) || "",
    kind: displayValue(value.kind) || "job",
    state,
    labels: stringList(value.labels),
    repository: repositoryLabel(value.repository ?? value.repository_slug),
    dependencies: stringList(value.dependencies ?? value.depends_on_proposal_slugs ?? input.depends_on),
    jobDependencyIds: stringList(value.depends_on_job_ids ?? input.depends_on_job_ids),
    epicDependencyIds: stringList(value.depends_on_epic_ids ?? input.depends_on_epic_ids),
    dependencyRequirements: dependencyRequirements(value.dependency_requirements ?? input.dependency_requirements),
    targetEpicId: isPlainObject(value.target_epic) ? displayValue(value.target_epic.id) : displayValue(value.target_epic_id ?? input.epic_id),
    targetEpicLabel: isPlainObject(value.target_epic)
      ? displayValue(value.target_epic.label) || displayValue(value.target_epic.title) || displayValue(value.target_epic.slug)
      : displayValue(value.target_epic_label),
    investigation: value.investigation === true,
    initialJobState: displayValue(value.initial_job_state) || (value.route_to_backlog === true ? "backlog" : null),
    providerSetting: displayValue(value.provider_setting) || displayValue(input.provider),
    plannedExecutionText: objectSummary(value.planned_execution ?? input.planned_execution),
    capabilitiesText: plannedExecutionCapabilitiesText(value.planned_execution ?? input.planned_execution),
    goalProvenanceText: objectSummary(value.goal_provenance),
    media: proposalMedia(stringList(input.media), presentation),
    materialized: parseMaterialized(value.materialized)
  }
}

function humanizeKind(kind: string): string {
  return kind.includes("epic") ? "Epic" : "Job"
}

export function proposalOutcomeSummary(proposal: ProposalOutcome): string {
  const label = proposal.title || proposal.slug
  return `${humanizeKind(proposal.kind)} proposal: ${label} (${proposal.state})`
}

function MaterializedOutcomeDetail({ materialized }: { materialized: MaterializedOutcome }) {
  if (!materialized) return null

  if (materialized.kind === "job") {
    return (
      <div className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300">
        <span>
          Materialized as <EntityReference id={materialized.jobId} kind="job" />
          {materialized.jobTitle ? ` · ${materialized.jobTitle}` : ""}
        </span>
        {materialized.jobState ? <StatePill state={materialized.jobState} /> : null}
      </div>
    )
  }

  if (materialized.kind === "epic") {
    return (
      <div className="min-w-0 text-gray-700 dark:text-gray-300">
        <div>
          Materialized as <EntityReference id={materialized.epicId} kind="epic" />
        </div>
        {materialized.childJobs.length > 0 ? (
          <div className="mt-2">
            <SectionLabel>Child Jobs ({materialized.childJobs.length})</SectionLabel>
            <ul className="mt-1 space-y-1">
              {materialized.childJobs.map((child) => (
                <li className="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1" key={child.jobId}>
                  <EntityReference id={child.jobId} kind="job" />
                  {child.title ? <span className="min-w-0 break-words [overflow-wrap:anywhere]">{child.title}</span> : null}
                </li>
              ))}
            </ul>
          </div>
        ) : null}
      </div>
    )
  }

  return <div className="text-gray-700 dark:text-gray-300">Rejected: {materialized.reason.replace(/_/g, " ")}</div>
}

function DetailValue({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className="break-words text-xs [overflow-wrap:anywhere]">{children}</div>
    </div>
  )
}

// Deliberately concise: this renders a tool call's *outcome* (state,
// dependencies, materialized result), not the full interactive proposal
// card (ProposalCards.tsx's ProposalCard), which already renders separately
// for the same chat_proposal item and owns edit/confirm/reject controls.
export function ProposalOutcomeCard({ proposal }: { proposal: ProposalOutcome }) {
  const hasDetails =
    proposal.repository ||
    proposal.targetEpicLabel ||
    proposal.targetEpicId ||
    proposal.dependencies.length > 0 ||
    proposal.jobDependencyIds.length > 0 ||
    proposal.epicDependencyIds.length > 0 ||
    proposal.dependencyRequirements.length > 0 ||
    proposal.investigation ||
    proposal.initialJobState ||
    proposal.providerSetting ||
    proposal.plannedExecutionText ||
    proposal.goalProvenanceText
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <Badge>{humanizeKind(proposal.kind)}</Badge>
        <StatePill state={proposal.state} />
        <EntityReference kind="proposal" slug={proposal.slug} />
      </div>
      {proposal.title ? <div className="min-w-0 break-words text-sm font-medium text-gray-900 dark:text-gray-100">{proposal.title}</div> : null}
      <MarkdownPreview
        emptyState={<div className="text-xs italic text-text-muted">No description provided.</div>}
        linkifySlugs
        linkifyUrls
        maxChars={960}
        modalLabel={`Full ${humanizeKind(proposal.kind)} description`}
        text={proposal.body}
        title="Description"
      />
      {proposal.labels.length > 0 ? (
        <div className="flex flex-wrap gap-1">
          {proposal.labels.map((label) => (
            <Badge key={label}>{label}</Badge>
          ))}
        </div>
      ) : null}
      {hasDetails ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          {proposal.repository ? (
            <DetailValue label="Repository">
              <EntityReference kind="repository" slug={proposal.repository} />
            </DetailValue>
          ) : null}
          {proposal.targetEpicLabel || proposal.targetEpicId ? (
            <DetailValue label="Target epic">
              {proposal.targetEpicId ? (
                <EntityReference id={proposal.targetEpicId} kind="epic" label={proposal.targetEpicLabel} slug={proposal.targetEpicLabel} />
              ) : (
                proposal.targetEpicLabel
              )}
            </DetailValue>
          ) : null}
          {proposal.dependencies.length > 0 ? (
            <DetailValue label="Proposal dependencies">
              <span className="flex flex-wrap gap-2">
                {proposal.dependencies.map((slug) => (
                  <EntityReference key={slug} kind="proposal" slug={slug} />
                ))}
              </span>
            </DetailValue>
          ) : null}
          {proposal.jobDependencyIds.length > 0 ? (
            <DetailValue label="Job dependencies">
              <span className="flex flex-wrap gap-2">
                {proposal.jobDependencyIds.map((id) => (
                  <EntityReference id={id} key={id} kind="job" />
                ))}
              </span>
            </DetailValue>
          ) : null}
          {proposal.epicDependencyIds.length > 0 ? (
            <DetailValue label="Epic dependencies">
              <span className="flex flex-wrap gap-2">
                {proposal.epicDependencyIds.map((id) => (
                  <EntityReference id={id} key={id} kind="epic" />
                ))}
              </span>
            </DetailValue>
          ) : null}
          {proposal.dependencyRequirements.length > 0 ? (
            <DetailValue label="Dependency requirements">
              {proposal.dependencyRequirements.map((requirement) => (
                <div key={`${requirement.target}-${requirement.mode}`}>
                  {requirement.target.startsWith("JOB-") ? (
                    <EntityReference id={requirement.target.slice(4)} kind="job" />
                  ) : (
                    <EntityReference kind="proposal" slug={requirement.target} />
                  )}{" "}
                  · {requirement.mode.replace(/_/g, " ")}
                  {requirement.stage ? `: ${requirement.stage}` : ""}
                </div>
              ))}
            </DetailValue>
          ) : null}
          {proposal.investigation ? <DetailValue label="Work type">Investigation</DetailValue> : null}
          {proposal.initialJobState ? <DetailValue label="Initial state">{proposal.initialJobState}</DetailValue> : null}
          {proposal.providerSetting ? <DetailValue label="Provider">{proposal.providerSetting}</DetailValue> : null}
          {proposal.plannedExecutionText ? <DetailValue label="Planned execution">{proposal.plannedExecutionText}</DetailValue> : null}
          {proposal.capabilitiesText ? <DetailValue label="Capabilities">{proposal.capabilitiesText}</DetailValue> : null}
          {proposal.goalProvenanceText ? <DetailValue label="Goal provenance">{proposal.goalProvenanceText}</DetailValue> : null}
        </dl>
      ) : null}
      {proposal.media.length > 0 ? (
        <div>
          <SectionLabel>Media</SectionLabel>
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
            {proposal.media.map((media) => (
              <MediaPreviewShell
                item={{
                  title: media.title,
                  subtitle: media.detail,
                  src: media.previewKind === "image" ? media.src : null,
                  alt: media.title,
                  badge: media.kind,
                  fallbackLabel: media.kind,
                  thumbnailChildren:
                    media.previewKind === "metadata" ? (
                      <MediaMetadataPreview media={media} />
                    ) : media.previewKind === "frame" && media.src ? (
                      <iframe
                        aria-label={`${media.title} thumbnail`}
                        className="pointer-events-none h-full w-full bg-white"
                        src={media.src}
                        title={`${media.title} thumbnail`}
                      />
                    ) : undefined,
                  previewChildren:
                    media.previewKind === "metadata" ? (
                      <MediaMetadataPreview media={media} />
                    ) : media.previewKind === "frame" && media.src ? (
                      <iframe className="h-[60dvh] w-full bg-white" src={media.src} title={media.title} />
                    ) : undefined,
                  actions: [...(media.src ? [{ label: "Open", href: media.src }] : []), { label: "Copy reference", copyValue: media.reference }]
                }}
                key={media.reference}
                thumbnailClassName="w-full"
              />
            ))}
          </div>
        </div>
      ) : null}
      <MaterializedOutcomeDetail materialized={proposal.materialized} />
    </CardShell>
  )
}

function MediaMetadataPreview({ media }: { media: ProposalMedia }) {
  return (
    <span className="flex h-full w-full flex-col items-center justify-center gap-1 px-2 text-center text-text-muted">
      <span className="text-2xs font-semibold uppercase">{media.kind}</span>
      <span className="max-w-full break-words text-xs text-text-primary">{media.title}</span>
      <span className="text-2xs">{media.detail}</span>
    </span>
  )
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
