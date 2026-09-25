import { deleteJson, getJson, postJson } from "./client"

export type AdminInvitation = {
  id: number
  email_address: string
  token: string
  share_url: string
  expires_at: string
  created_at: string
  invited_by_email_address: string
}

export type AdminInvitationsPayload = {
  invitations: AdminInvitation[]
  filter: Record<string, unknown> | null
  filter_schema: Array<Record<string, unknown>>
  filters: Record<string, unknown>
  total: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
    has_previous_page: boolean
    has_next_page: boolean
    previous_page: number | null
    next_page: number | null
    first_item: number
    last_item: number
  }
  sort: { column: string; direction: "asc" | "desc" }
  message?: string
}

export function fetchAdminInvitations(search = "") {
  return getJson<AdminInvitationsPayload>(`/api/v1/app/admin/invitations${search}`)
}

export function createAdminInvitation(emailAddress: string) {
  return postJson<AdminInvitationsPayload>("/api/v1/app/admin/invitations", {
    invitation: { email_address: emailAddress }
  })
}

export function revokeAdminInvitation(id: number) {
  return deleteJson<AdminInvitationsPayload>(`/api/v1/app/admin/invitations/${id}`)
}
