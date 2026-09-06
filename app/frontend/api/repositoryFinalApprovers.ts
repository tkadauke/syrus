import { deleteJson, getJson, postJson } from "./client"

export type RepositoryFinalApproverUser = {
  id: number
  name: string
  email_address: string
}

export type RepositoryFinalApprover = {
  id: number
  created_at: string
  user: RepositoryFinalApproverUser
}

export type RepositoryFinalApproversPayload = {
  final_approvers: RepositoryFinalApprover[]
  message?: string
}

export function fetchRepositoryFinalApprovers(repositoryId: number) {
  return getJson<RepositoryFinalApproversPayload>(`/api/v1/app/repositories/${repositoryId}/final_approvers`)
}

export function createRepositoryFinalApprover(repositoryId: number, email: string) {
  return postJson<RepositoryFinalApproversPayload>(`/api/v1/app/repositories/${repositoryId}/final_approvers`, { email })
}

export function deleteRepositoryFinalApprover(repositoryId: number, finalApproverId: number) {
  return deleteJson<RepositoryFinalApproversPayload>(`/api/v1/app/repositories/${repositoryId}/final_approvers/${finalApproverId}`)
}
