import { getJson, postJson } from "./client"
import type { AdminEventFilterPayload } from "../components/AdminEventLogPanel"

export type AttentionItemAction = {
  action_key: string
  label: string | null
  detail: string | null
  payload: Record<string, unknown>
}

export type AttentionItemRepository = { id: number; slug: string; path: string }
export type AttentionItemJob = { id: number; slug: string; title: string | null; state: string; path: string }
export type AttentionItemWorkflow = { id: number; slug: string; trigger_kind: string | null; state: string; path: string }
export type AttentionItemStep = { id: number; kind: string; state: string }
export type AttentionItemUser = { id: number; display_name: string; email_address: string }

export type AttentionItemAdjudication = {
  verdict: string
  reason?: string | null
  adjudicator?: string | null
  confidence?: number | null
  evidence?: Record<string, unknown>
}

export type AttentionItemSummary = {
  id: number
  problem_code: string
  problem_label: string
  signature: string
  title: string
  summary: string | null
  queue: string
  urgency: string
  state: string
  resolution: string | null
  reason: string | null
  evidence: Record<string, unknown>
  adjudication: AttentionItemAdjudication | null
  actions: AttentionItemAction[]
  repository: AttentionItemRepository | null
  job: AttentionItemJob | null
  workflow: AttentionItemWorkflow | null
  step: AttentionItemStep | null
  decided_by: AttentionItemUser | null
  decided_at: string | null
  expires_at: string | null
  created_at: string
}

export type AdminAttentionItemsPayload = AdminEventFilterPayload & {
  items: AttentionItemSummary[]
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
    first_item: number
    last_item: number
    previous_path: string | null
    next_path: string | null
  }
}

export function fetchAdminAttentionItems(search = "", signal?: AbortSignal) {
  return getJson<AdminAttentionItemsPayload>(`/api/v1/app/admin/attention_items${search}`, { signal })
}

export function decideAdminAttentionItem(id: number, resolution: string, reason?: string) {
  return postJson<AttentionItemSummary>(`/api/v1/app/admin/attention_items/${id}/decide`, { resolution, reason })
}

export function actOnAdminAttentionItem(id: number, actionKey: string, reason?: string) {
  return postJson<AttentionItemSummary>(`/api/v1/app/admin/attention_items/${id}/act`, { action_key: actionKey, reason })
}
