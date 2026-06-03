import { getJson, postJson } from "./client"

export type InstallationRepository = {
  id: number
  slug: string
  owner: string
  name: string
  owner_user: {
    id: number
    email_address: string
    admin: boolean
  }
  app_credential_active: boolean
  credential_mode: "app" | "pat" | string
  account_login: string
  installation_removed_at: string | null
  github_owner_id: number | null
  github_repository_id: number | null
}

export type PatOwnerGroup = {
  owner: string
  repository_count: number
  install_url: string | null
}

export type AdminInstallationsPayload = {
  github_app_registered: boolean
  github_app_slug: string | null
  pat_owner_groups: PatOwnerGroup[]
  repositories: InstallationRepository[]
  ok?: boolean
  message?: string
}

export function fetchAdminInstallations() {
  return getJson<AdminInstallationsPayload>("/api/v1/app/admin/installations")
}

export function refreshInstallations() {
  return postJson<AdminInstallationsPayload>("/api/v1/app/admin/installations/refresh")
}
