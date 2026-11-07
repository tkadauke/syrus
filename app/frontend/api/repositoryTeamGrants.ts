import { deleteJson, patchJson, postJson } from "./client"
import type { RepositoryMembershipRole } from "./repositoryMemberships"

export type TeamRepositoryGrant = {
  id: number
  role: RepositoryMembershipRole
  created_at: string
  team: {
    id: number
    name: string
  }
}

export function createRepositoryTeamGrant(repositoryId: number, values: { team_name: string; role: RepositoryMembershipRole }) {
  return postJson<{ team_grant: TeamRepositoryGrant; message: string }>(`/api/v1/app/repositories/${repositoryId}/team_grants`, values)
}

export function updateRepositoryTeamGrantRole(repositoryId: number, grantId: number, role: RepositoryMembershipRole) {
  return patchJson<{ team_grant: TeamRepositoryGrant; message: string }>(`/api/v1/app/repositories/${repositoryId}/team_grants/${grantId}`, { role })
}

export function deleteRepositoryTeamGrant(repositoryId: number, grantId: number) {
  return deleteJson<{ id: number; message: string }>(`/api/v1/app/repositories/${repositoryId}/team_grants/${grantId}`)
}
