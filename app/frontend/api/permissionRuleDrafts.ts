import { getJson, postJson } from "./client"

export type DraftPolicy = "allow" | "ask" | "deny"
export type DraftDuration = "chat_session" | "job" | "permanent"
export type ScopeFieldType = "string" | "integer" | "boolean" | "select"
/** Provider-owned description of one resource-scope input. */
export type ScopeField = { name: string; label: string; type: ScopeFieldType; choices?: Array<{ value: string; label: string }> }

export type RuleDraftFields = {
  policy: DraftPolicy
  duration: DraftDuration
  subject_selector_type: string
  subject_selector_id: string
  subject_type: string
  subject_repository_id: string
  role: string
  capability: string
  operation: string
  resource_scope: Record<string, unknown>
  constraints: Record<string, unknown>
  chat_session_id: string
  job_id: string
  rationale: string
}

export type RuleDraftSubjectType = {
  type: string
  requires_id: boolean
  requires_repository: boolean
  roles: string[]
  exact_agent: boolean
}

export type RuleDraftOptions = {
  capability: string
  operation: string
  policies: DraftPolicy[]
  risk: string
  subject_types: RuleDraftSubjectType[]
  resource_scope: { type: string; options?: { fields?: ScopeField[] } | null }
  constraint_fields: Record<string, "string" | "integer" | "boolean">
  authority_durations: DraftDuration[]
  maximum_autonomy: string
  maximum_duration_seconds: number | null
  permanent_allowed: boolean
  ceilings: Array<{ id: number; layer: string; policy: string; subject_selector_type: string }>
}

export type RuleDraftIssue = { code: string; message: string }
export type RuleDraftPreview = {
  valid: boolean
  errors: RuleDraftIssue[]
  warnings: RuleDraftIssue[]
  digest: string | null
  draft: {
    policy: DraftPolicy
    duration: DraftDuration
    role: string
    subject: { type: string; id: string | null; subject_type: string | null; repository_id: number | null }
    capability: string
    operation: string
    resource_scope: Record<string, unknown>
    resource_scope_label: string
    constraints: Record<string, unknown>
    chat_session_id: number | null
    job_id: number | null
    expires_at: string | null
    rationale: string | null
  } | null
  summary: { allows: string[]; excludes: string[] } | null
  ceiling: {
    maximum_autonomy: string
    maximum_duration_seconds: number | null
    permanent_allowed: boolean
    limited_by: { id: number | string; layer: string; policy: string } | null
  } | null
  examples: { matches: string[]; non_matches: string[] } | null
}

export const EMPTY_DRAFT: RuleDraftFields = {
  policy: "allow",
  duration: "permanent",
  subject_selector_type: "",
  subject_selector_id: "",
  subject_type: "",
  subject_repository_id: "",
  role: "",
  capability: "",
  operation: "",
  resource_scope: {},
  constraints: {},
  chat_session_id: "",
  job_id: "",
  rationale: ""
}

const BASE = "/api/v1/app/permission_rule_drafts"

/** Server-friendly body: blank strings are omitted so the draft stays canonical. */
export function draftBody(fields: RuleDraftFields) {
  const entries = Object.entries(fields).filter(([, value]) => value !== "" && value != null)
  return Object.fromEntries(entries)
}

export const fetchRuleDraftOptions = (capability: string, operation: string) =>
  getJson<{ options: RuleDraftOptions }>(`${BASE}/options?capability=${encodeURIComponent(capability)}&operation=${encodeURIComponent(operation)}`)

export const previewRuleDraft = (fields: RuleDraftFields, request?: { requestId: number; itemId: number }) =>
  postJson<{ preview: RuleDraftPreview }>(`${BASE}/preview`, {
    draft: draftBody(fields),
    ...(request ? { request_id: request.requestId, item_id: request.itemId } : {})
  })

export const previewRuleDraftFromRequest = (
  requestId: number,
  itemId: number,
  duration: DraftDuration,
  policy: DraftPolicy = "allow",
  prefix?: string
) =>
  postJson<{ preview: RuleDraftPreview }>(`${BASE}/from_request`, {
    request_id: requestId,
    item_id: itemId,
    duration,
    policy,
    ...(prefix ? { prefix } : {})
  })

export const applyRuleDraft = (fields: RuleDraftFields, digest: string, options: { replaceRuleId?: number | null } = {}) =>
  postJson<{ authority: { kind: string; id: number; capability: string; operation: string | null } }>(`${BASE}/apply`, {
    draft: draftBody(fields),
    digest,
    ...(options.replaceRuleId ? { replace_rule_id: options.replaceRuleId } : {})
  })

/** Maps a server preview's normalized draft back onto editable fields. */
export function fieldsFromPreview(preview: RuleDraftPreview): RuleDraftFields {
  const draft = preview.draft
  if (!draft) return EMPTY_DRAFT
  return {
    policy: draft.policy,
    duration: draft.duration,
    subject_selector_type: draft.subject.type,
    subject_selector_id: draft.subject.id ?? "",
    subject_type: draft.subject.subject_type ?? "",
    subject_repository_id: draft.subject.repository_id ? String(draft.subject.repository_id) : "",
    role: draft.role,
    capability: draft.capability,
    operation: draft.operation,
    resource_scope: draft.resource_scope,
    constraints: draft.constraints,
    chat_session_id: draft.chat_session_id ? String(draft.chat_session_id) : "",
    job_id: draft.job_id ? String(draft.job_id) : "",
    rationale: draft.rationale ?? ""
  }
}
