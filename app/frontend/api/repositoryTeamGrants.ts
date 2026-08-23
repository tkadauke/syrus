import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { RepositoryMembershipRole, RepositoryMembershipsPayload } from "./repositoryMemberships"

export type TeamRepositoryGrant = {
  id: number
  role: RepositoryMembershipRole
  created_at: string
  team: {
    id: number
    name: string
  }
}

export function fetchRepositoryTeamGrants(repositoryId: string) {
  return getJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/team_grants`)
}

export function createRepositoryTeamGrant(repositoryId: number, values: { team_name: string; role: RepositoryMembershipRole }) {
  return postJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/team_grants`, values)
}

export function updateRepositoryTeamGrantRole(repositoryId: number, grantId: number, role: RepositoryMembershipRole) {
  return patchJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/team_grants/${grantId}`, { role })
}

export function deleteRepositoryTeamGrant(repositoryId: number, grantId: number) {
  return deleteJson<RepositoryMembershipsPayload>(`/api/v1/app/repositories/${repositoryId}/team_grants/${grantId}`)
}
