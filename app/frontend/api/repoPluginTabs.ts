import { getJson } from "./client"

export type RepoPluginTab = {
  id: string
  label: string
  label_key?: string | null
  path: string
  paths: string[]
  order: number
  component?: string | null
  badge?: number | null
}

export type RepoPluginTabsPayload = {
  tabs: RepoPluginTab[]
}

export function fetchRepoPluginTabs(repositoryId: string | number) {
  return getJson<RepoPluginTabsPayload>(`/api/v1/app/repositories/${repositoryId}/plugin_tabs`)
}
