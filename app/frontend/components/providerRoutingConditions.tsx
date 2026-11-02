import { useState } from "react"
import type { ReactNode } from "react"
import { Checkbox, Form } from "./ui"
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

// Later condition types (usage, day_time, job_metadata, repository) register here.
const CONDITION_TYPES: ConditionType[] = [workflowTrigger]

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
