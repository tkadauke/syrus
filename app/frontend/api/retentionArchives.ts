import { getJson } from "./client"

export type RetentionArchiveRow = {
  id: number
  pruned_before: string
  row_count: number
  byte_size: number
  created_at: string
  filename: string | null
  download_path: string | null
}

export type RetentionArchivesPagination = {
  page: number
  per_page: number
  total: number
  total_pages: number
  first_item: number
  last_item: number
}

export type RetentionArchivesPayload = {
  retention_key: string
  archives: RetentionArchiveRow[]
  pagination: RetentionArchivesPagination
}

export function fetchRetentionArchives(retentionKey: string, page: number) {
  const params = new URLSearchParams({ retention_key: retentionKey, page: String(page) })
  return getJson<RetentionArchivesPayload>(`/api/v1/app/admin/retention_archives?${params.toString()}`)
}
