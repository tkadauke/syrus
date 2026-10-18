import { getJson } from "./client"

export type WorkflowPreviewStep = {
  id?: number
  display_name?: string
  status?: string
  ellipsis?: boolean
}

export type WorkflowPreview = {
  id: number
  slug: string
  path: string
  trigger_kind: string
  trigger_label: string
  state: string
  steps: WorkflowPreviewStep[]
}

export function fetchWorkflowPreview(id: number, signal?: AbortSignal) {
  return getJson<{ workflow: WorkflowPreview }>(`/api/v1/app/workflows/${id}/preview`, { signal })
}
