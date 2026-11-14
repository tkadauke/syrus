import { deleteJson, patchJson, postJson } from "./client"

export type ProviderModelOption = {
  id: string
  label: string
  context_window?: string
  cost_tier?: string
}

export type AgentProviderOption = {
  value: string
  label: string
  configured?: boolean
  models: ProviderModelOption[]
}

export type EffortLevelOption = {
  value: string
  label: string
}

export type ProviderRoutingCandidate = {
  provider: string
  model?: string | null
  effort_level?: string | null
  reviewer_target?: ProviderRoutingReviewerTarget | null
}

export type ProviderRoutingReviewerTarget = {
  type: string
  reference: string
  display: { name: string; handle?: string; role_summary?: string }
}

export type ProviderRoutingTrigger =
  { type: "default" } | { type: "step"; kind: string } | { type: "chat_role"; role: string } | { type: "legacy_task"; task_key: string }

export type ProviderRoutingConditions = {
  workflow_trigger_kind?: string[]
  usage?: Record<string, unknown>
  budget?: Record<string, unknown>
  day_time?: Record<string, unknown>
  repository?: Record<string, unknown>
  job_metadata?: Record<string, unknown>
  [key: string]: unknown
}

export type ProviderRoutingAction = {
  type?: "route" | "hold"
  strategy?: string
  candidates?: ProviderRoutingCandidate[]
  reason?: string
  name?: string
  consensus?: "unanimous" | "majority" | { at_least: number }
  on_unavailable?: "drop" | "hold" | "fail"
  min_members?: number
  [key: string]: unknown
}

export type ProviderRoutingRule = {
  id: number
  scope_type: "user" | "repository" | "job"
  scope_id: number
  user_id?: number
  repository_id?: number | null
  job_id?: number | null
  position?: number
  enabled?: boolean
  task_key: string
  trigger?: ProviderRoutingTrigger
  conditions?: ProviderRoutingConditions
  action?: ProviderRoutingAction
  candidates: ProviderRoutingCandidate[]
  created_at?: string
  updated_at?: string
}

export type ProviderRoutingRegistryOption = {
  value: string
  label: string
  style?: string
  panel_capable?: boolean
}

export type ProviderUsageReading = {
  provider: string
  state?: string
  remaining_percent?: number | string | null
  observed_at?: string | null
}

export type ProviderRoutingRepositoryOption = {
  id: number
  owner: string
  name: string
  slug: string
}

export type ProviderRoutingRegistryOptions = {
  triggers?: {
    chat_roles?: ProviderRoutingRegistryOption[]
    step_kinds?: ProviderRoutingRegistryOption[]
  }
  conditions?: {
    workflow_trigger_kinds?: ProviderRoutingRegistryOption[]
    provider_usage?: ProviderUsageReading[]
    job_kinds?: ProviderRoutingRegistryOption[]
    repositories?: ProviderRoutingRepositoryOption[]
    time_zone?: string
  }
  action_strategies?: ProviderRoutingRegistryOption[]
  action_types?: ProviderRoutingRegistryOption[]
  condition_keys?: ProviderRoutingRegistryOption[]
}

export type ProviderRoutingOptions = {
  agent_providers: AgentProviderOption[]
  effort_levels: EffortLevelOption[]
  reviewer_targets?: ProviderRoutingReviewerTarget[]
  review_contributions?: import("../pluginReviewContributions").ReviewContribution[]
} & ProviderRoutingRegistryOptions

export type ProviderRoutingInheritedContext = {
  scope_type: "user" | "repository" | "job"
  scope_id: number
  label: string
  rules: ProviderRoutingRule[]
}

export type ProviderRoutingRulesPayload = {
  provider_routing_rules: ProviderRoutingRule[]
  provider_routing_options: ProviderRoutingOptions
  inherited_provider_routing_context?: ProviderRoutingInheritedContext[]
}

export type ProviderRoutingRuleInput = {
  task_key: string
  position?: number
  enabled?: boolean
  trigger?: ProviderRoutingTrigger
  conditions?: ProviderRoutingConditions
  action?: ProviderRoutingAction
  candidates: ProviderRoutingCandidate[]
}

export function createProviderRoutingRule(path: string, values: ProviderRoutingRuleInput) {
  return postJson<ProviderRoutingRulesPayload>(path, { provider_routing_rule: values })
}

export function updateProviderRoutingRule(path: string, values: ProviderRoutingRuleInput) {
  return patchJson<ProviderRoutingRulesPayload>(path, { provider_routing_rule: values })
}

export function deleteProviderRoutingRule(path: string) {
  return deleteJson<ProviderRoutingRulesPayload>(path)
}

export function reorderProviderRoutingRules(path: string, ids: number[]) {
  return patchJson<ProviderRoutingRulesPayload>(`${path}/reorder`, { provider_routing_rule_ids: ids })
}

export type ProviderRoutingConditionResult = {
  configured?: boolean
  matched: boolean
  expected?: unknown
  actual?: unknown
  predicate_results?: Record<string, boolean>
  reason?: string
}

export type ProviderRoutingRuleEvidence = {
  matched: boolean
  trigger?: { matched: boolean; expected?: unknown; actual?: unknown }
  conditions?: Record<string, ProviderRoutingConditionResult>
}

export type ProviderRoutingRuleTrace = {
  id: number
  position: number
  enabled: boolean
  outcome: "matched_winner" | "match_failed" | "disabled_skipped" | "not_evaluated_after_winner" | "overridden_by_explicit_pin"
  winning: boolean
  trigger?: ProviderRoutingTrigger
  conditions?: ProviderRoutingConditions
  action?: ProviderRoutingAction
  evidence: ProviderRoutingRuleEvidence[]
}

export type ProviderRoutingExplanation = {
  job_id: number
  scope_precedence: Array<{ scope_type: string; scope_id: number; rules: ProviderRoutingRuleTrace[] }>
  explicit_pin?: { provider?: string; model?: string }
  winning_decision: {
    fallback?: boolean
    reason?: string
    decision?: { status: string; reason?: string }
    matched_rule?: { id: number }
    final_action?: { candidates?: ProviderRoutingCandidate[]; reason?: string }
  }
}

export type ProviderRoutingExplainInput = {
  target_job_id: number
  task_key: string
  workflow_trigger_kind?: string
}

export function explainProviderRouting(path: string, values: ProviderRoutingExplainInput) {
  return postJson<ProviderRoutingExplanation>(`${path}/explain`, values)
}
