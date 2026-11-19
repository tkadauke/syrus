import { getJson } from "@app/api/client"

export type LocalBackup = {
  uuid: string
  state: string
  artifact_path: string
  manifest_version: number
  database_adapter: string | null
  logical_bytes: number
  stored_bytes: number
  blob_count: number
  checksum_algorithm: string
  checksum: string
  verification_state: string
  source_application_version: string | null
  completed_at: string
  validated_at: string
}

export type LocalBackupsPayload = {
  configured: boolean
  root?: string
  error?: string
  backups: LocalBackup[]
  invalid_artifacts: Array<{ path: string; error: string }>
}

export const fetchLocalBackups = () => getJson<LocalBackupsPayload>("/api/v1/app/admin/local_backups")
