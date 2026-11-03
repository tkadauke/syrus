import { useState } from "react"
import type { ReactNode } from "react"
import { Button, Checkbox, Form } from "./ui"
import type { ProviderRoutingConditions, ProviderRoutingOptions } from "../api/providerRoutingRules"

export type ConditionT = (key: string, options?: Record<string, unknown>) => string

export type ConditionCardProps = {
  onChange: (value: unknown) => void
  options: ProviderRoutingOptions
  t: ConditionT
  value: unknown
}

export type ConditionScope = "user" | "repository" | "job"

export type ConditionType = {
  key: string
  /** Scopes where the condition is redundant and therefore hidden from the editor (stored values are still kept on save). */
  hiddenAtScopes?: ConditionScope[]
  /** i18n key for the short label shown in the menu and card title. */
  labelKey: string
  defaultValue: () => unknown
  Card: (props: ConditionCardProps) => ReactNode
  /** Terse human summary for the rule list; null/empty hides the condition. */
  summarize: (value: unknown, options: ProviderRoutingOptions, t: ConditionT) => string | null
  /** Whether a value is empty and should be dropped on save (matches everything). */
  isEmpty?: (value: unknown) => boolean
  /** Returns an error message when the value cannot be saved, otherwise null. */
  validate?: (value: unknown, t: ConditionT) => string | null
}

// Keys the backend accepts but the UI never offers or renders as active conditions.
const HIDDEN_KEYS = new Set(["budget"])

export function stringList(value: unknown) {
  return (Array.isArray(value) ? value : value == null ? [] : [value]).map((entry) => String(entry).trim()).filter(Boolean)
}

function WorkflowTriggerCard({ onChange, options, t, value }: ConditionCardProps) {
  const [query, setQuery] = useState("")
  const selected = stringList(value)
  const needle = query.trim().toLowerCase()
  const kinds = (options.conditions?.workflow_trigger_kinds || []).filter(
    (option) => !needle || option.label.toLowerCase().includes(needle) || option.value.toLowerCase().includes(needle)
  )

  function toggle(kind: string, checked: boolean) {
    onChange(checked ? [...selected, kind] : selected.filter((entry) => entry !== kind))
  }

  return (
    <div className="space-y-2">
      <Form.Field>
        <Form.Input
          aria-label={t("provider_routing.conditions.search_workflow")}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("provider_routing.conditions.search_workflow")}
          type="search"
          value={query}
        />
      </Form.Field>
      <div className="max-h-44 overflow-y-auto rounded border border-border">
        {kinds.map((option) => (
          <label className="flex min-h-10 cursor-pointer items-center gap-2 px-2 text-sm text-text-primary" key={option.value}>
            <Checkbox
              checked={selected.includes(option.value)}
              className="h-4 w-4 accent-brand"
              onChange={(event) => toggle(option.value, event.target.checked)}
            />
            {option.label}
          </label>
        ))}
        {kinds.length === 0 ? <p className="px-2 py-2 text-xs text-text-secondary">{t("provider_routing.conditions.no_matches")}</p> : null}
      </div>
    </div>
  )
}

const WORKFLOW_PILL_MAX = 2

const workflowTrigger: ConditionType = {
  key: "workflow_trigger_kind",
  labelKey: "provider_routing.conditions.workflow_trigger_kind",
  defaultValue: () => [],
  Card: WorkflowTriggerCard,
  isEmpty: (value) => stringList(value).length === 0,
  summarize: (value, options, t) => {
    const labels = stringList(value).map((kind) => options.conditions?.workflow_trigger_kinds?.find((option) => option.value === kind)?.label || kind)
    if (labels.length === 0) return null
    const shown = labels.slice(0, WORKFLOW_PILL_MAX).join(", ")
    const extra = labels.length - WORKFLOW_PILL_MAX
    return t("provider_routing.workflow_condition_pill", { label: extra > 0 ? `${shown} +${extra}` : shown })
  }
}

const USAGE_COMPARATORS = [
  { key: "remaining_percent_less_than", symbol: "<", labelKey: "provider_routing.usage.less_than" },
  { key: "remaining_percent_less_than_or_equal_to", symbol: "≤", labelKey: "provider_routing.usage.at_most" },
  { key: "remaining_percent_greater_than", symbol: ">", labelKey: "provider_routing.usage.more_than" },
  { key: "remaining_percent_greater_than_or_equal_to", symbol: "≥", labelKey: "provider_routing.usage.at_least" }
] as const

const USAGE_STATES = ["available", "rate_limited", "exhausted", "open", "auth_error", "model_unsupported"]
const DEFAULT_USAGE_COMPARATOR = USAGE_COMPARATORS[0].key

type UsageValue = Record<string, unknown>

function usageValue(value: unknown): UsageValue {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as UsageValue) : {}
}

/** The comparator currently stored on the condition (first one found) and its raw percent. */
export function usageComparator(value: unknown) {
  const stored = usageValue(value)
  const found = USAGE_COMPARATORS.find((comparator) => comparator.key in stored)
  return { comparator: found ?? USAGE_COMPARATORS[0], percent: found ? stored[found.key] : undefined }
}

function usagePercent(raw: unknown): number | null {
  if (raw === undefined || raw === null || raw === "") return null
  const number = typeof raw === "number" ? raw : Number(raw)
  return Number.isFinite(number) ? number : null
}

/** Pure card-state -> stored JSON: swaps the comparator key / percent, preserving every other key. */
export function setUsageComparison(value: unknown, comparatorKey: string, percent: string | number | undefined): UsageValue {
  const next: UsageValue = { ...usageValue(value) }
  USAGE_COMPARATORS.forEach((comparator) => delete next[comparator.key])
  if (percent !== undefined && percent !== "") {
    const number = Number(percent)
    next[comparatorKey] = Number.isFinite(number) ? number : percent
  }
  return next
}

function providerLabel(provider: string | undefined, options: ProviderRoutingOptions) {
  if (!provider) return ""
  return options.agent_providers?.find((option) => option.value === provider)?.label || provider
}

function usageMatches(comparatorKey: string, actual: number, expected: number) {
  if (comparatorKey === "remaining_percent_less_than") return actual < expected
  if (comparatorKey === "remaining_percent_less_than_or_equal_to") return actual <= expected
  if (comparatorKey === "remaining_percent_greater_than") return actual > expected
  return actual >= expected
}

/** Live one-line hint from the current availability reading, or null when there is nothing to compare. */
export function usageHint(value: unknown, options: ProviderRoutingOptions, t: ConditionT): string | null {
  const stored = usageValue(value)
  const provider = typeof stored.provider === "string" ? stored.provider : ""
  if (!provider) return null
  const label = providerLabel(provider, options)
  const reading = options.conditions?.provider_usage?.find((entry) => entry.provider === provider)
  const remaining = usagePercent(reading?.remaining_percent)
  if (remaining === null) return t("provider_routing.usage.hint_unknown", { provider: label })
  const { comparator, percent } = usageComparator(value)
  const expected = usagePercent(percent)
  const rounded = Math.round(remaining)
  if (expected === null) return t("provider_routing.usage.hint_now", { provider: label, percent: rounded })
  const states = stringList(stored.states)
  const stateOk = states.length === 0 || states.includes(reading?.state || "available")
  const matches = stateOk && usageMatches(comparator.key, remaining, expected)
  return t(matches ? "provider_routing.usage.hint_match" : "provider_routing.usage.hint_no_match", { provider: label, percent: rounded })
}

function UsageCard({ onChange, options, t, value }: ConditionCardProps) {
  const stored = usageValue(value)
  const { comparator: storedComparator, percent } = usageComparator(value)
  // The comparator only exists in stored JSON while a percent is present, so keep the
  // selection locally to survive clearing the percent field.
  const [pendingKey, setPendingKey] = useState<string>(storedComparator.key)
  const hasStoredComparator = USAGE_COMPARATORS.some((entry) => entry.key in stored)
  const comparator = USAGE_COMPARATORS.find((entry) => entry.key === (hasStoredComparator ? storedComparator.key : pendingKey)) ?? USAGE_COMPARATORS[0]
  const states = stringList(stored.states)
  const [showMore, setShowMore] = useState(states.length > 0)
  const error = usageError(value, t)
  const hint = usageHint(value, options, t)

  function patch(partial: UsageValue) {
    const next = { ...stored, ...partial }
    Object.keys(next).forEach((key) => {
      if (next[key] === undefined || (key === "provider" && next[key] === "") || (key === "states" && stringList(next[key]).length === 0)) delete next[key]
    })
    onChange(next)
  }

  function toggleState(state: string) {
    patch({ states: states.includes(state) ? states.filter((entry) => entry !== state) : [...states, state] })
  }

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap gap-2">
        <Form.Field className="min-w-28 flex-1">
          <Form.Select
            aria-label={t("provider_routing.usage.provider")}
            onChange={(event) => patch({ provider: event.target.value })}
            value={typeof stored.provider === "string" ? stored.provider : ""}
          >
            <option value="">{t("provider_routing.usage.job_provider")}</option>
            {(options.agent_providers || []).map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </Form.Select>
        </Form.Field>
        <Form.Field className="min-w-28 flex-1">
          <Form.Select
            aria-label={t("provider_routing.usage.comparator")}
            onChange={(event) => {
              setPendingKey(event.target.value)
              onChange(setUsageComparison(stored, event.target.value, percent as string | number | undefined))
            }}
            value={comparator.key}
          >
            {USAGE_COMPARATORS.map((option) => (
              <option key={option.key} value={option.key}>
                {t(option.labelKey)}
              </option>
            ))}
          </Form.Select>
        </Form.Field>
        <Form.Field className="w-24">
          <Form.Input
            aria-label={t("provider_routing.usage.percent")}
            inputMode="decimal"
            max={100}
            min={0}
            onChange={(event) => onChange(setUsageComparison(stored, comparator.key, event.target.value))}
            placeholder="%"
            type="number"
            value={percent === undefined || percent === null ? "" : String(percent)}
          />
        </Form.Field>
      </div>
      {error ? (
        <p className="text-xs text-danger" role="alert">
          {error}
        </p>
      ) : null}
      {hint ? <p className="text-xs text-text-secondary">{hint}</p> : null}
      <Button aria-expanded={showMore} onClick={() => setShowMore((open) => !open)} size="sm" variant="secondary">
        {t("provider_routing.usage.more")}
      </Button>
      {showMore ? (
        <div aria-label={t("provider_routing.usage.states")} className="flex flex-wrap gap-2" role="group">
          {USAGE_STATES.map((state) => (
            <button
              aria-pressed={states.includes(state)}
              className={`min-h-9 rounded-full border px-3 text-xs ${states.includes(state) ? "border-brand bg-brand/10 text-text-primary" : "border-border text-text-secondary"}`}
              key={state}
              onClick={() => toggleState(state)}
              type="button"
            >
              {t(`provider_routing.usage.state_${state}`)}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}

function usageError(value: unknown, t: ConditionT): string | null {
  const { percent } = usageComparator(value)
  if (percent === undefined) return null
  const number = usagePercent(percent)
  if (number === null || number < 0 || number > 100) return t("provider_routing.usage.validation_percent")
  return null
}

const usage: ConditionType = {
  key: "usage",
  labelKey: "provider_routing.conditions.usage",
  defaultValue: () => ({ [DEFAULT_USAGE_COMPARATOR]: 25 }),
  Card: UsageCard,
  validate: usageError,
  summarize: (value, options, t) => {
    const stored = usageValue(value)
    const { comparator, percent } = usageComparator(value)
    const number = usagePercent(percent)
    const provider = typeof stored.provider === "string" ? stored.provider : ""
    const label = provider ? providerLabel(provider, options) : t("provider_routing.usage.job_provider_short")
    if (number === null) return provider ? t("provider_routing.usage.pill_provider", { provider: label }) : null
    return t("provider_routing.usage.pill", { provider: label, symbol: comparator.symbol, percent: number })
  }
}

function Chip({ label, onClick, pressed }: { label: string; onClick: () => void; pressed: boolean }) {
  return (
    <button
      aria-pressed={pressed}
      className={`min-h-9 rounded-full border px-3 text-xs ${pressed ? "border-brand bg-brand/10 text-text-primary" : "border-border text-text-secondary"}`}
      onClick={onClick}
      type="button"
    >
      {label}
    </button>
  )
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : {}
}

/** Merges a partial update into a condition object, dropping keys that became empty. */
function patchObject(value: unknown, partial: Record<string, unknown>): Record<string, unknown> {
  const next: Record<string, unknown> = { ...objectValue(value), ...partial }
  Object.keys(next).forEach((key) => {
    const entry = next[key]
    if (entry === undefined || entry === "" || (Array.isArray(entry) && entry.length === 0)) delete next[key]
  })
  return next
}

function toggled<T>(list: T[], item: T) {
  return list.includes(item) ? list.filter((entry) => entry !== item) : [...list, item]
}

function joinWithExtra(labels: string[], max: number, separator = "/") {
  const shown = labels.slice(0, max).join(separator)
  return labels.length > max ? `${shown} +${labels.length - max}` : shown
}

// ---- Day and time -------------------------------------------------------

export const DAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] as const
const TIME_PATTERN = /^\d{2}:\d{2}$/

export function dayTimeDays(value: unknown) {
  return stringList(objectValue(value).days)
}

export function toggleDay(value: unknown, day: string) {
  const days = dayTimeDays(value)
  const next = toggled(days, day)
  return patchObject(value, { days: DAYS.filter((entry) => next.includes(entry)) })
}

export function setDayTimeBound(value: unknown, key: "start" | "end", time: string) {
  return patchObject(value, { [key]: time })
}

/** The backend compares HH:MM strings, so start after end (overnight) never matches. */
function dayTimeError(value: unknown, t: ConditionT): string | null {
  const stored = objectValue(value)
  const start = String(stored.start ?? "")
  const end = String(stored.end ?? "")
  if (TIME_PATTERN.test(start) && TIME_PATTERN.test(end) && start > end) return t("provider_routing.day_time.validation_overnight")
  return null
}

function dayLabel(day: string, t: ConditionT) {
  return t(`provider_routing.day_time.short_${day}`)
}

/** Contiguous runs collapse to `Mon-Fri`; everything else is listed. All seven days = no restriction. */
export function dayTimeDaysSummary(days: string[], t: ConditionT): string | null {
  const indexes = DAYS.map((day, index) => (days.includes(day) ? index : -1)).filter((index) => index >= 0)
  if (indexes.length === 0 || indexes.length === DAYS.length) return null
  const contiguous = indexes.length > 2 && indexes[indexes.length - 1] - indexes[0] === indexes.length - 1
  if (contiguous) return `${dayLabel(DAYS[indexes[0]], t)}-${dayLabel(DAYS[indexes[indexes.length - 1]], t)}`
  return indexes.map((index) => dayLabel(DAYS[index], t)).join(", ")
}

function DayTimeCard({ onChange, options, t, value }: ConditionCardProps) {
  const stored = objectValue(value)
  const days = dayTimeDays(value)
  const error = dayTimeError(value, t)
  const zone = options.conditions?.time_zone

  return (
    <div className="space-y-2">
      <div aria-label={t("provider_routing.day_time.days")} className="flex flex-wrap gap-2" role="group">
        {DAYS.map((day) => (
          <Chip key={day} label={dayLabel(day, t)} onClick={() => onChange(toggleDay(value, day))} pressed={days.includes(day)} />
        ))}
      </div>
      <div className="flex flex-wrap gap-2">
        <Form.Field className="min-w-28 flex-1">
          <Form.Input
            aria-label={t("provider_routing.day_time.start")}
            onChange={(event) => onChange(setDayTimeBound(value, "start", event.target.value))}
            type="time"
            value={String(stored.start ?? "")}
          />
        </Form.Field>
        <Form.Field className="min-w-28 flex-1">
          <Form.Input
            aria-label={t("provider_routing.day_time.end")}
            onChange={(event) => onChange(setDayTimeBound(value, "end", event.target.value))}
            type="time"
            value={String(stored.end ?? "")}
          />
        </Form.Field>
      </div>
      {zone ? <p className="text-xs text-text-secondary">{t("provider_routing.day_time.zone", { zone })}</p> : null}
      {error ? (
        <p className="text-xs text-danger" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  )
}

const dayTime: ConditionType = {
  key: "day_time",
  labelKey: "provider_routing.conditions.day_time",
  defaultValue: () => ({ days: ["monday", "tuesday", "wednesday", "thursday", "friday"], start: "09:00", end: "18:00" }),
  Card: DayTimeCard,
  isEmpty: (value) => dayTimeDays(value).length === 0 && !objectValue(value).start && !objectValue(value).end,
  validate: dayTimeError,
  summarize: (value, _options, t) => {
    const stored = objectValue(value)
    const parts: string[] = []
    const daysLabel = dayTimeDaysSummary(dayTimeDays(value), t)
    if (daysLabel) parts.push(daysLabel)
    const start = String(stored.start ?? "")
    const end = String(stored.end ?? "")
    if (start && end) parts.push(`${start}-${end}`)
    else if (start) parts.push(t("provider_routing.day_time.from", { time: start }))
    else if (end) parts.push(t("provider_routing.day_time.until", { time: end }))
    return parts.length > 0 ? parts.join(" ") : null
  }
}

// ---- Job type -----------------------------------------------------------

export const JOB_PRIORITIES = ["urgent", "high", "medium", "low"] as const
export type InvestigationMode = "any" | "only" | "never"

export function investigationMode(value: unknown): InvestigationMode {
  const stored = objectValue(value)
  if (!("investigation" in stored)) return "any"
  return stored.investigation === true || stored.investigation === "true" ? "only" : "never"
}

export function setInvestigationMode(value: unknown, mode: InvestigationMode) {
  const next = { ...objectValue(value) }
  if (mode === "any") delete next.investigation
  else next.investigation = mode === "only"
  return next
}

function titleize(raw: string) {
  const text = raw.replace(/_/g, " ")
  return text.charAt(0).toUpperCase() + text.slice(1)
}

const JOB_PILL_MAX = 2

function JobMetadataCard({ onChange, options, t, value }: ConditionCardProps) {
  const stored = objectValue(value)
  const kinds = stringList(stored.kinds)
  const priorities = stringList(stored.priorities)
  const mode = investigationMode(value)
  const modes: { mode: InvestigationMode; label: string }[] = [
    { mode: "any", label: t("provider_routing.job_metadata.any") },
    { mode: "only", label: t("provider_routing.job_metadata.only_investigations") },
    { mode: "never", label: t("provider_routing.job_metadata.never_investigations") }
  ]

  return (
    <div className="space-y-3">
      <div aria-label={t("provider_routing.job_metadata.kinds")} className="flex flex-wrap gap-2" role="group">
        {(options.conditions?.job_kinds || []).map((kind) => (
          <Chip
            key={kind.value}
            label={kind.label}
            onClick={() => onChange(patchObject(value, { kinds: toggled(kinds, kind.value) }))}
            pressed={kinds.includes(kind.value)}
          />
        ))}
      </div>
      <div aria-label={t("provider_routing.job_metadata.priorities")} className="flex flex-wrap gap-2" role="group">
        {JOB_PRIORITIES.map((priority) => (
          <Chip
            key={priority}
            label={t(`provider_routing.job_metadata.priority_${priority}`)}
            onClick={() => onChange(patchObject(value, { priorities: toggled(priorities, priority) }))}
            pressed={priorities.includes(priority)}
          />
        ))}
      </div>
      <div aria-label={t("provider_routing.job_metadata.investigation")} className="flex flex-wrap gap-2" role="radiogroup">
        {modes.map((entry) => (
          <button
            aria-checked={mode === entry.mode}
            className={`min-h-9 rounded-full border px-3 text-xs ${mode === entry.mode ? "border-brand bg-brand/10 text-text-primary" : "border-border text-text-secondary"}`}
            key={entry.mode}
            onClick={() => onChange(setInvestigationMode(value, entry.mode))}
            role="radio"
            type="button"
          >
            {entry.label}
          </button>
        ))}
      </div>
    </div>
  )
}

const jobMetadata: ConditionType = {
  key: "job_metadata",
  labelKey: "provider_routing.conditions.job_metadata",
  defaultValue: () => ({}),
  Card: JobMetadataCard,
  isEmpty: (value) => {
    const stored = objectValue(value)
    return stringList(stored.kinds).length === 0 && stringList(stored.priorities).length === 0 && !("investigation" in stored)
  },
  summarize: (value, options, t) => {
    const stored = objectValue(value)
    const parts: string[] = []
    const kinds = stringList(stored.kinds).map((kind) => options.conditions?.job_kinds?.find((option) => option.value === kind)?.label || titleize(kind))
    if (kinds.length > 0) parts.push(joinWithExtra(kinds, JOB_PILL_MAX))
    const priorities = stringList(stored.priorities).map((priority) =>
      (JOB_PRIORITIES as readonly string[]).includes(priority) ? t(`provider_routing.job_metadata.priority_${priority}`) : titleize(priority)
    )
    if (priorities.length > 0) parts.push(priorities.join("/"))
    const mode = investigationMode(value)
    if (mode === "only") parts.push(t("provider_routing.job_metadata.pill_investigations"))
    if (mode === "never") parts.push(t("provider_routing.job_metadata.pill_no_investigations"))
    return parts.length > 0 ? parts.join(" · ") : null
  }
}

// ---- Repository ---------------------------------------------------------

const REPOSITORY_LABEL_MAX = 24
const REPOSITORY_PILL_MAX = 2

function truncate(text: string, max = REPOSITORY_LABEL_MAX) {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text
}

export function repositoryIds(value: unknown) {
  const ids = objectValue(value).ids
  return (Array.isArray(ids) ? ids : []).map((id) => Number(id)).filter((id) => Number.isFinite(id))
}

function RepositoryCard({ onChange, options, t, value }: ConditionCardProps) {
  const [query, setQuery] = useState("")
  const stored = objectValue(value)
  const ids = repositoryIds(value)
  const owners = stringList(stored.owners)
  const names = stringList(stored.names)
  const repositories = options.conditions?.repositories || []
  const knownOwners = Array.from(new Set([...repositories.map((repository) => repository.owner), ...owners])).sort()
  const needle = query.trim().toLowerCase()
  const visible = repositories.filter((repository) => !needle || repository.slug.toLowerCase().includes(needle))

  return (
    <div className="space-y-3">
      <div aria-label={t("provider_routing.repository.owners")} className="flex flex-wrap gap-2" role="group">
        {knownOwners.map((owner) => (
          <Chip key={owner} label={owner} onClick={() => onChange(patchObject(value, { owners: toggled(owners, owner) }))} pressed={owners.includes(owner)} />
        ))}
      </div>
      <Form.Field>
        <Form.Input
          aria-label={t("provider_routing.repository.search")}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t("provider_routing.repository.search")}
          type="search"
          value={query}
        />
      </Form.Field>
      <div className="max-h-44 overflow-y-auto rounded border border-border">
        {visible.map((repository) => (
          <label className="flex min-h-10 cursor-pointer items-center gap-2 px-2 text-sm text-text-primary" key={repository.id}>
            <Checkbox
              checked={ids.includes(repository.id)}
              className="h-4 w-4 accent-brand"
              onChange={() => onChange(patchObject(value, { ids: toggled(ids, repository.id) }))}
            />
            {repository.slug}
          </label>
        ))}
        {visible.length === 0 ? <p className="px-2 py-2 text-xs text-text-secondary">{t("provider_routing.conditions.no_matches")}</p> : null}
      </div>
      {names.length > 0 ? (
        <div aria-label={t("provider_routing.repository.names")} className="flex flex-wrap gap-2" role="group">
          {names.map((name) => (
            <Chip key={name} label={name} onClick={() => onChange(patchObject(value, { names: toggled(names, name) }))} pressed />
          ))}
        </div>
      ) : null}
    </div>
  )
}

const repository: ConditionType = {
  key: "repository",
  labelKey: "provider_routing.conditions.repository",
  hiddenAtScopes: ["repository", "job"],
  defaultValue: () => ({}),
  Card: RepositoryCard,
  isEmpty: (value) => {
    const stored = objectValue(value)
    return repositoryIds(value).length === 0 && stringList(stored.owners).length === 0 && stringList(stored.names).length === 0
  },
  summarize: (value, options, t) => {
    const stored = objectValue(value)
    const known = options.conditions?.repositories || []
    const labels = [
      ...repositoryIds(value).map((id) => known.find((entry) => entry.id === id)?.slug || `#${id}`),
      ...stringList(stored.owners),
      ...stringList(stored.names)
    ].map((label) => truncate(label))
    if (labels.length === 0) return null
    return t("provider_routing.repository.pill", { label: joinWithExtra(labels, REPOSITORY_PILL_MAX, ", ") })
  }
}

const CONDITION_TYPES: ConditionType[] = [workflowTrigger, usage, dayTime, jobMetadata, repository]

/** Condition types offered at the given scope (repository is redundant inside a repository or job rule set). */
function typesForScope(scope: ConditionScope) {
  return CONDITION_TYPES.filter((type) => !type.hiddenAtScopes?.includes(scope))
}

export function conditionTypes() {
  return CONDITION_TYPES
}

export function conditionType(key: string) {
  return CONDITION_TYPES.find((type) => type.key === key)
}

/** Registered conditions currently on the rule, in registry order. */
export function activeConditionTypes(conditions: ProviderRoutingConditions, scope: ConditionScope = "user") {
  return typesForScope(scope).filter((type) => type.key in conditions)
}

/** First validation error among the registered conditions present on the rule, or null. */
export function conditionsError(conditions: ProviderRoutingConditions, t: ConditionT): string | null {
  for (const type of CONDITION_TYPES) {
    if (!(type.key in conditions)) continue
    const error = type.validate?.(conditions[type.key], t)
    if (error) return error
  }
  return null
}

/** Drops registered conditions whose value is empty; everything else is kept verbatim. */
export function pruneEmptyConditions(conditions: ProviderRoutingConditions): ProviderRoutingConditions {
  const next = { ...conditions }
  CONDITION_TYPES.forEach((type) => {
    if (type.key in next && type.isEmpty?.(next[type.key])) delete next[type.key]
  })
  return next
}

export function availableConditionTypes(conditions: ProviderRoutingConditions, scope: ConditionScope = "user") {
  return typesForScope(scope).filter((type) => !(type.key in conditions))
}

/** Unknown keys (budget is hidden entirely) that the UI cannot render; they are preserved on save. */
export function unknownConditionCount(conditions: ProviderRoutingConditions = {}) {
  return Object.keys(conditions).filter((key) => !conditionType(key) && !HIDDEN_KEYS.has(key)).length
}

export function conditionSummaries(conditions: ProviderRoutingConditions = {}, options: ProviderRoutingOptions, t: ConditionT) {
  const labels: string[] = []
  CONDITION_TYPES.forEach((type) => {
    if (!(type.key in conditions)) return
    const summary = type.summarize(conditions[type.key], options, t)
    if (summary) labels.push(summary)
  })
  const unknown = unknownConditionCount(conditions)
  if (unknown > 0) labels.push(t("provider_routing.conditions.other", { count: unknown }))
  return labels
}
