import { deleteJson, getJson, patchJson, postJson } from "./client"

export const TEAM_MEMBERSHIP_ROLES = ["member", "owner"] as const
export type TeamMembershipRole = (typeof TEAM_MEMBERSHIP_ROLES)[number]

export type AdminTeamRow = {
  id: number
  name: string
  member_count: number
  repository_count: number
  owned_by_current_user: boolean
  team_path: string
}

export type TeamMembershipUser = {
  id: number
  email_address: string
  name: string
}

export type TeamMembership = {
  id: number
  role: TeamMembershipRole
  created_at: string
  user: TeamMembershipUser
}

export type TeamRepositoryGrant = {
  id: number
  role: "read" | "write" | "admin"
  created_at: string
  repository: {
    id: number
    slug: string
  }
}

export type AdminTeamsPayload = {
  teams: AdminTeamRow[]
  message?: string
}

export type AdminTeamDetailPayload = {
  team: AdminTeamRow
  can_manage: boolean
  memberships: TeamMembership[]
  repository_grants: TeamRepositoryGrant[]
  message?: string
}

export function fetchAdminTeams() {
  return getJson<AdminTeamsPayload>("/api/v1/app/teams")
}

export function fetchAdminTeam(id: string) {
  return getJson<AdminTeamDetailPayload>(`/api/v1/app/teams/${id}`)
}

export function createAdminTeam(name: string) {
  return postJson<AdminTeamsPayload>("/api/v1/app/teams", { team: { name } })
}

export function renameAdminTeam(id: number, name: string) {
  return patchJson<AdminTeamDetailPayload>(`/api/v1/app/teams/${id}`, { team: { name } })
}

export function deleteAdminTeam(id: number) {
  return deleteJson<AdminTeamsPayload>(`/api/v1/app/teams/${id}`)
}

export function addTeamMember(teamId: number, values: { email: string; role: TeamMembershipRole }) {
  return postJson<AdminTeamDetailPayload>(`/api/v1/app/teams/${teamId}/memberships`, values)
}

export function updateTeamMemberRole(teamId: number, membershipId: number, role: TeamMembershipRole) {
  return patchJson<AdminTeamDetailPayload>(`/api/v1/app/teams/${teamId}/memberships/${membershipId}`, { role })
}

export function removeTeamMember(teamId: number, membershipId: number) {
  return deleteJson<AdminTeamDetailPayload>(`/api/v1/app/teams/${teamId}/memberships/${membershipId}`)
}
