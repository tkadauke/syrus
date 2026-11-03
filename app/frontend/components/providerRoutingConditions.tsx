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

export type ConditionType = {
  key: string
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
  const { comparator, percent } = usageComparator(value)
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
            onChange={(event) => onChange(setUsageComparison(stored, event.target.value, percent as string | number | undefined))}
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

// Later condition types (day_time, job_metadata, repository) register here.
const CONDITION_TYPES: ConditionType[] = [workflowTrigger, usage]

export function conditionTypes() {
  return CONDITION_TYPES
}

export function conditionType(key: string) {
  return CONDITION_TYPES.find((type) => type.key === key)
}

/** Registered conditions currently on the rule, in registry order. */
export function activeConditionTypes(conditions: ProviderRoutingConditions) {
  return CONDITION_TYPES.filter((type) => type.key in conditions)
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

export function availableConditionTypes(conditions: ProviderRoutingConditions) {
  return CONDITION_TYPES.filter((type) => !(type.key in conditions))
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
