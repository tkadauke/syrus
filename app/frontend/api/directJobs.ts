import { getJson, postForm } from "./client"

export type DirectJobRepository = {
  id: number
  slug: string
  repository_path: string
  default_agent_provider: string
  default_agent_provider_label: string
}

export type DirectJobAgentProvider = {
  value: string
  label: string
}

export type DirectJobPromptTemplate = {
  id: string
  name: string
  description: string
  prompt: string
}

export type DirectJobPriority = {
  value: string
  label: string
  description: string
}

export type DirectJobFormPayload = {
  repositories: DirectJobRepository[]
  configured_agent_providers: DirectJobAgentProvider[]
  selected_repository_id: string | null
  selected_agent_provider: string | null
  create_more: boolean
  prompt_templates: DirectJobPromptTemplate[]
  priorities: DirectJobPriority[]
  accepted_file_content_types: string[]
  new_repository_path: string
  dashboard_jobs_path: string
}

export type CreateDirectJobInput = {
  repositoryId: string
  agentProvider: string
  title: string
  prompt: string
  priority: string
  createMore: boolean
  files: File[]
  googleDocUrl: string
}

export type DirectJobCreatedPayload = {
  message: string
  create_more: boolean
  redirect_to: string
  job: {
    id: number
    title: string
    title_pending?: boolean
    state: string
    repository: DirectJobRepository
    job_path: string
  }
}

export function fetchDirectJobForm(search = "") {
  return getJson<DirectJobFormPayload>(`/api/v1/app/jobs/new${search}`)
}

export function createDirectJob(values: CreateDirectJobInput) {
  const formData = new FormData()
  formData.append("repository_id", values.repositoryId)
  formData.append("agent_provider", values.agentProvider)
  formData.append("title", values.title)
  formData.append("prompt", values.prompt)
  formData.append("priority", values.priority)
  if (values.createMore) {
    formData.append("create_more", "1")
  }
  values.files.forEach((file) => {
    formData.append("job_attachment[files][]", file)
  })
  formData.append("job_attachment[google_doc_url]", values.googleDocUrl)

  return postForm<DirectJobCreatedPayload>("/api/v1/app/jobs", formData)
}
