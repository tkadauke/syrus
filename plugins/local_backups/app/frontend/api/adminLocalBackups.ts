import { deleteJson, getJson, postJson } from "@app/api/client"

export type LocalBackup = {
  uuid: string
  reason: string | null
  database_adapter: string | null
  logical_bytes: number
  stored_bytes: number
  blob_count: number
  completed_at: string
  validated_at: string | null
  verification_state: string | null
  source_application_version: string | null
  artifact_checksum: string
  checksum_algorithm: string
  encryption_key_fingerprint: string | null
  pinned: boolean
  state: string
}

export type LocalBackupsPayload = {
  root: { configured: boolean; path?: string; available_bytes?: number; error?: string }
  scan: { discovered: number; invalid: Array<{ path: string; error: string }> }
  backups: LocalBackup[]
}

export function fetchAdminLocalBackups() {
  return getJson<LocalBackupsPayload>("/api/v1/app/admin/local_backups")
}

export const createLocalBackup = () => postJson("/api/v1/app/admin/local_backups") as Promise<{ queued: boolean }>
export const validateLocalBackup = (id: string) => postJson(`/api/v1/app/admin/local_backups/${id}/validate`)
export const pinLocalBackup = (id: string) => postJson(`/api/v1/app/admin/local_backups/${id}/pin`)
export const unpinLocalBackup = (id: string) => deleteJson(`/api/v1/app/admin/local_backups/${id}/pin`)
export const deleteLocalBackup = (id: string) => deleteJson(`/api/v1/app/admin/local_backups/${id}`)
export const localBackupDownloadUrl = (id: string) => `/api/v1/app/admin/local_backups/${id}/download`
