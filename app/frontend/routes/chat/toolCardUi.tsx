import { useMemo, useState, type ReactNode } from "react"
import { CopyableSlug, CopyIcon } from "../../components/CopyableSlug"
import { SlugHoverCard } from "../../components/SlugHoverCard"
import { CodeSurface, Input, Pill, Surface, Text, ToolCard } from "../../components/ui"
import type { SemanticTone } from "../../components/ui"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import { useT } from "../../hooks/useT"
import { formatCurrency } from "../../lib/format"
import { formatDuration } from "../jobDetail/formatting"

// Shared presentation primitives for the Workflow/Run/PR/diff/ops tool cards
// (the Tier 1 tool-card work). Lives outside `tool_cards/` on purpose: the
// pluginToolCards.tsx directory glob treats every non-test .tsx file under
// `tool_cards/` as a card module and would warn about a missing default
// export (see jobsTableCard.tsx for the established precedent).
export function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

export function numberValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value)
  return null
}

export function decimalCost(value: unknown): string | null {
  const amount = numberValue(value)
  if (amount == null) return null
  return formatCurrency(amount)
}

export function durationLabel(startedAt: unknown, finishedAt: unknown): string | null {
  const started = displayValue(startedAt)
  const finished = displayValue(finishedAt)
  if (!started || !finished) return null
  const label = formatDuration(started, finished)
  return label === "-" ? null : label
}

type Tone = "success" | "failure" | "warning" | "info" | "neutral"

const TONE_TO_SEMANTIC_TONE: Record<Tone, SemanticTone> = {
  success: "success",
  failure: "danger",
  warning: "warning",
  info: "info",
  neutral: "neutral"
}

export function stateTone(state: string | null | undefined): Tone {
  const normalized = (state || "").toLowerCase()
  if (["succeeded", "success", "approved", "merged", "current", "repaired", "confirmed", "fired"].includes(normalized)) return "success"
  if (["failed", "failure", "error", "alarm", "cancelled", "canceled", "no_effective_ci_repair", "rejected", "withdrawn"].includes(normalized)) return "failure"
  if (["blocked", "paused", "auto_paused", "stale", "operator_action_required", "auto_repairable", "waiting"].includes(normalized)) return "warning"
  if (["running", "queued", "pending", "landing", "proposed", "confirming", "scheduled"].includes(normalized)) return "info"
  return "neutral"
}

export function StatePill({ state, tone }: { state: string; tone?: Tone }) {
  const resolvedTone = tone ?? stateTone(state)
  return <Pill className="text-2xs font-semibold uppercase" tone={TONE_TO_SEMANTIC_TONE[resolvedTone]}>{state.replace(/_/g, " ")}</Pill>
}

export function Badge({ children }: { children: ReactNode }) {
  return <Pill className="text-2xs" tone="neutral">{children}</Pill>
}

export function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <Text as="div" variant="label" tone="muted">{label}</Text>
      <Text as="div" className="truncate font-mono text-xs" title={value}>{value}</Text>
    </div>
  )
}

export function SectionLabel({ children }: { children: ReactNode }) {
  return <Text as="div" variant="label" tone="muted">{children}</Text>
}

export function CardShell({ children }: { children: ReactNode }) {
  return <ToolCard.Root className="mt-1 space-y-2">{children}</ToolCard.Root>
}

export function EmptyState({ children }: { children: ReactNode }) {
  return (
    <Surface className="mt-1" padding="sm" variant="inset">
      <Text as="div" variant="caption" tone="muted">{children}</Text>
    </Surface>
  )
}

export function InternalLink({ href, children }: { href: string; children: ReactNode }) {
  return (
    <a className="font-mono font-medium text-brand hover:underline dark:text-brand-emphasis" href={href}>
      {children}
    </a>
  )
}

export type ToolCardEntityKind =
  | "job"
  | "epic"
  | "design_doc"
  | "chat"
  | "run"
  | "workflow"
  | "pull_request"
  | "artifact"
  | "repository"
  | "proposal"

export type EntityReferenceProps = {
  kind: ToolCardEntityKind
  id?: number | string | null
  slug?: string | null
  label?: string | null
  href?: string | null
  jobId?: number | string | null
  workflowId?: number | string | null
  repositoryId?: number | string | null
  repositorySlug?: string | null
  prUrl?: string | null
  className?: string
}

function compactEntityValue(value: number | string | null | undefined): string | null {
  return displayValue(value)
}

function prefixedEntityLabel(prefix: string, id: number | string | null | undefined) {
  const displayed = compactEntityValue(id)
  return displayed ? `${prefix}-${displayed}` : null
}

type EntityReferenceDefinition = {
  label: (reference: EntityReferenceProps) => string | null
  href: (reference: EntityReferenceProps) => string | null
  copyValue?: (reference: EntityReferenceProps, label: string) => string | null
  hoverKind?: "job" | "epic" | "chat" | "plugin"
  hoverPrefix?: string
}

const slugCopyValue = (reference: EntityReferenceProps, label: string) => displayValue(reference.slug) ?? label
const noHref = () => null
const idHref = (prefix: string) => (reference: EntityReferenceProps) => {
  const id = compactEntityValue(reference.id)
  return id ? `${prefix}/${id}` : null
}
const repositoryHref = (reference: EntityReferenceProps) => {
  const id = compactEntityValue(reference.repositoryId) ?? compactEntityValue(reference.id)
  return id ? `/repositories/${id}` : null
}

const ENTITY_REFERENCE_DEFINITIONS: Record<ToolCardEntityKind, EntityReferenceDefinition> = {
  job: { label: (reference) => prefixedEntityLabel("JOB", reference.id), href: idHref("/jobs"), copyValue: slugCopyValue, hoverKind: "job" },
  epic: { label: (reference) => prefixedEntityLabel("EPIC", reference.id), href: idHref("/epics"), copyValue: slugCopyValue, hoverKind: "epic" },
  design_doc: { label: (reference) => prefixedEntityLabel("DOC", reference.id), href: idHref("/design_docs"), copyValue: slugCopyValue, hoverKind: "plugin", hoverPrefix: "DOC" },
  chat: { label: (reference) => prefixedEntityLabel("CHAT", reference.id), href: idHref("/chats"), copyValue: slugCopyValue, hoverKind: "chat" },
  run: { label: (reference) => prefixedEntityLabel("RUN", reference.id), href: (reference) => {
    const jobId = compactEntityValue(reference.jobId)
    const workflowId = compactEntityValue(reference.workflowId)
    return jobId && workflowId ? `/jobs/${jobId}?tab=workflows#workflow-${workflowId}` : null
  }, copyValue: slugCopyValue },
  workflow: { label: (reference) => prefixedEntityLabel("WF", reference.id), href: (reference) => {
    const id = compactEntityValue(reference.id)
    const jobId = compactEntityValue(reference.jobId)
    return id && jobId ? `/jobs/${jobId}?tab=workflows#workflow-${id}` : null
  }, copyValue: slugCopyValue },
  pull_request: { label: (reference) => {
    const id = compactEntityValue(reference.id)
    return id ? `PR #${id}` : null
  }, href: (reference) => displayValue(reference.prUrl) },
  artifact: { label: (reference) => compactEntityValue(reference.id), href: noHref, copyValue: slugCopyValue },
  repository: { label: (reference) => displayValue(reference.repositorySlug), href: repositoryHref, copyValue: slugCopyValue },
  proposal: { label: (reference) => compactEntityValue(reference.id), href: noHref, copyValue: slugCopyValue }
}

export function entityReferenceLabel(reference: EntityReferenceProps): string | null {
  const explicit = displayValue(reference.label) ?? displayValue(reference.slug)
  return explicit ?? ENTITY_REFERENCE_DEFINITIONS[reference.kind].label(reference)
}

export function entityReferenceHref(reference: EntityReferenceProps): string | null {
  const explicit = displayValue(reference.href)
  if (explicit) return explicit
  return ENTITY_REFERENCE_DEFINITIONS[reference.kind].href(reference)
}

function entityCopyValue(reference: EntityReferenceProps, label: string): string | null {
  return ENTITY_REFERENCE_DEFINITIONS[reference.kind].copyValue?.(reference, label) ?? null
}

function hoverWrapper(reference: EntityReferenceProps, children: ReactNode) {
  const id = numberValue(reference.id)
  if (id == null) return children
  const definition = ENTITY_REFERENCE_DEFINITIONS[reference.kind]
  return definition.hoverKind ? <SlugHoverCard id={id} kind={definition.hoverKind} prefix={definition.hoverPrefix}>{children}</SlugHoverCard> : children
}

const COPY_ICON_BUTTON_CLASS = [
  "inline-flex h-5 w-5 shrink-0 items-center justify-center rounded",
  "text-text-subtle hover:bg-surface-raised hover:text-text-primary",
  "focus:outline-none focus:ring-2 focus:ring-brand"
].join(" ")

function CopyOnlyIconButton({ value }: { value: string }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()

  return (
    <button
      aria-label={t("copy.copy_to_clipboard", { slug: value })}
      className={COPY_ICON_BUTTON_CLASS}
      onClick={() => copy(value)}
      title={copied ? t("copy.copied") : t("copy.copy", { slug: value })}
      type="button"
    >
      <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-success-text" : ""}`} />
    </button>
  )
}

function linkedEntityReference(label: string, href: string, external: boolean) {
  const className = "min-w-0 break-all font-mono font-medium text-brand hover:underline dark:text-brand-emphasis"
  return <a className={className} href={href} rel={external ? "noreferrer" : undefined} target={external ? "_blank" : undefined}>{label}</a>
}

export function EntityReference(reference: EntityReferenceProps) {
  const label = entityReferenceLabel(reference)
  if (!label) return null

  const href = entityReferenceHref(reference)
  const copyValue = entityCopyValue(reference, label)
  const external = Boolean(href?.match(/^https?:\/\//))

  if (!href && copyValue) {
    return hoverWrapper(reference, <CopyableSlug className={`text-xs normal-case ${reference.className ?? ""}`} slug={copyValue} />)
  }

  const content = href ? (
    <span className={`inline-flex max-w-full min-w-0 items-center gap-1 ${reference.className ?? ""}`}>
      {linkedEntityReference(label, href, external)}
      {copyValue ? <CopyOnlyIconButton value={copyValue} /> : null}
    </span>
  ) : (
    <span className={`break-all font-mono font-medium text-text-primary ${reference.className ?? ""}`}>{label}</span>
  )

  return hoverWrapper(reference, content)
}

// Collapsed-by-default detail section for content a card should not dump
// into the main body by default (file contents, command output, long
// lists) — the raw JSON "Raw details" disclosure always covers the full
// payload regardless, so this is purely a friendlier, still-opt-in view.
export function Disclosure({ label, children }: { label: string; children: ReactNode }) {
  return (
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">{label}</summary>
      <div className="mt-1 text-text-primary">{children}</div>
    </details>
  )
}

export type LinePreview = { preview: string; truncated: boolean; totalLines: number }

export function truncateLines(text: string, maxLines: number): LinePreview {
  const lines = text.split("\n")
  if (lines.length <= maxLines) return { preview: text, truncated: false, totalLines: lines.length }
  return { preview: lines.slice(0, maxLines).join("\n"), truncated: true, totalLines: lines.length }
}

export function LargeTextPreview({ emptyLabel = "No text returned.", label, maxLines = 40, text }: { emptyLabel?: string; label: string; maxLines?: number; text: string | null }) {
  return (
    <Disclosure label={label}>
      <PreviewTextBlock emptyLabel={emptyLabel} maxLines={maxLines} text={text} />
    </Disclosure>
  )
}

export function PreviewTextBlock({ emptyLabel = "No text returned.", maxLines = 40, text }: { emptyLabel?: string; maxLines?: number; text: string | null }) {
  if (!text?.trim()) return <EmptyState>{emptyLabel}</EmptyState>

  const { preview, truncated, totalLines } = truncateLines(text, maxLines)

  return (
    <>
      <CodeSurface code={preview} maxHeightClassName="max-h-72" />
      {truncated ? <Text as="div" className="mt-1" variant="caption" tone="muted">Showing first {maxLines} of {totalLines} lines.</Text> : null}
    </>
  )
}

export function FilterableList<T,>({ children, emptyLabel = "No matching rows.", itemText, items, placeholder = "Filter results" }: { children: (items: T[]) => ReactNode; emptyLabel?: string; itemText: (item: T) => string; items: T[]; placeholder?: string }) {
  const [query, setQuery] = useState("")
  const normalizedQuery = query.trim().toLowerCase()
  const visibleItems = useMemo(() => {
    if (!normalizedQuery) return items
    return items.filter((item) => itemText(item).toLowerCase().includes(normalizedQuery))
  }, [itemText, items, normalizedQuery])

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input
          aria-label={placeholder}
          className="min-w-0 flex-1 px-2 py-1 text-xs"
          fullWidth={false}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={placeholder}
          type="search"
          value={query}
        />
        <Text as="span" variant="caption" tone="muted">{visibleItems.length} of {items.length}</Text>
      </div>
      {visibleItems.length > 0 ? children(visibleItems) : <EmptyState>{emptyLabel}</EmptyState>}
    </div>
  )
}
