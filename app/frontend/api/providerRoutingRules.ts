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
}

export type ProviderRoutingRule = {
  id: number
  scope_type: "user" | "repository"
  scope_id: number
  task_key: string
  candidates: ProviderRoutingCandidate[]
}

export type ProviderRoutingOptions = {
  agent_providers: AgentProviderOption[]
  effort_levels: EffortLevelOption[]
}

export type ProviderRoutingRulesPayload = {
  provider_routing_rules: ProviderRoutingRule[]
  provider_routing_options: ProviderRoutingOptions
}

export type ProviderRoutingRuleInput = {
  task_key: string
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
