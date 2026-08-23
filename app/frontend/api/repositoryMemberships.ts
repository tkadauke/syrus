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

export type RepositoryMembership = {
  id: number
  role: RepositoryMembershipRole
  agent_provider: string | null
  created_at: string
  user: RepositoryMembershipUser
}

export type RepositoryMembershipsPayload = {
  repository: RepositoryMembershipsRepository
  tabs: RepositoryTab[]
  memberships: RepositoryMembership[]
  team_grants: TeamRepositoryGrant[]
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
