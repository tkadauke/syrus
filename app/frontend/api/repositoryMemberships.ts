import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { RepositoryTab } from "./repositories"
import type { TeamRepositoryGrant } from "./repositoryTeamGrants"

export const REPOSITORY_MEMBERSHIP_ROLES = ["read", "write", "admin"] as const
export type RepositoryMembershipRole = (typeof REPOSITORY_MEMBERSHIP_ROLES)[number]

export type RepositoryMembershipsRepository = {
  id: number
  slug: string
  repository_path: string
}

export type RepositoryMembershipUser = {
  id: number
  email_address: string
  name: string
}

export const GITHUB_PERMISSION_MISMATCH_REASONS = [
  "no_github_handle",
  "not_a_github_collaborator",
  "insufficient_github_permission"
] as const
export type GithubPermissionMismatchReason = (typeof GITHUB_PERMISSION_MISMATCH_REASONS)[number]

export type RepositoryMembership = {
  id: number
  role: RepositoryMembershipRole
  agent_provider: string | null
  created_at: string
  github_permission_mismatch_reason: GithubPermissionMismatchReason | null
  github_permission_mismatch_checked_at: string | null
  user: RepositoryMembershipUser
}

export type GithubCollaboratorDiscrepancy = {
  id: number
  github_login: string
  github_permission: "write" | "admin"
  checked_at: string
}

export type RepositoryMembershipsPayload = {
  repository: RepositoryMembershipsRepository
  tabs: RepositoryTab[]
  memberships: RepositoryMembership[]
  team_grants: TeamRepositoryGrant[]
  github_collaborator_discrepancies: GithubCollaboratorDiscrepancy[]
  message?: string
}

export function fetchRepositoryMemberships(repositoryId: string) {
  return getJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/memberships`)
}

export function createRepositoryMembership(repositoryId: number, values: { email: string; role: RepositoryMembershipRole }) {
  return postJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/memberships`, values)
}

export function updateRepositoryMembershipRole(repositoryId: number, membershipId: number, role: RepositoryMembershipRole) {
  return patchJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/memberships/${membershipId}`, { role })
}

export function deleteRepositoryMembership(repositoryId: number, membershipId: number) {
  return deleteJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/memberships/${membershipId}`)
}
