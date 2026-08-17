import { getJson, postJson } from "./client"

export type SkillParameterField = {
  key: string
  type: "string" | "text" | "boolean" | "integer" | "select"
  required: boolean
  label: string
  options: string[] | null
  default: unknown
  depends_on: string | null
}

export type SkillSummary = {
  name: string
  description: string
  source: "built_in" | "repo_override"
  resolved_path: string | null
  resolved_class: string | null
  shadows_built_in: boolean
  parameters: SkillParameterField[]
}

export type SkillAgentProvider = {
  value: string
  label: string
}

export type RepositorySkillsPayload = {
  repository: {
    id: number
    slug: string
    repository_path: string
    default_agent_provider: string
    default_agent_provider_label: string
  }
  skills: SkillSummary[]
  configured_agent_providers: SkillAgentProvider[]
  priorities: string[]
}

export type CreateSkillJobInput = {
  name: string
  args: Record<string, string | boolean>
  agentProvider: string
  priority: string
}

export type SkillJobCreatedPayload = {
  message: string
  redirect_to: string
  job: {
    id: number
    title: string
    state: string
    skill_name: string
    job_path: string
  }
}

export function fetchRepositorySkills(repositoryId: string) {
  return getJson<RepositorySkillsPayload>(`/api/v1/app/repositories/${repositoryId}/skills`)
}

export function createSkillJob(repositoryId: string, input: CreateSkillJobInput) {
  return postJson<SkillJobCreatedPayload>(`/api/v1/app/repositories/${repositoryId}/skills`, {
    name: input.name,
    args: input.args,
    agent_provider: input.agentProvider,
    priority: input.priority
  })
}
