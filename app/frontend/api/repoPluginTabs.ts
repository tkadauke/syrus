import { getJson } from "./client"
import { useQuery } from "@tanstack/react-query"

export type RepoPluginTab = {
  id: string
  key: string
  label: string
  label_key?: string | null
  path: string
  paths: string[]
  order: number
  component?: string | null
  badge?: number | string
}

export type RepoPluginTabsPayload = {
  tabs: RepoPluginTab[]
}

export function fetchRepoPluginTabs(repositoryId: string | number) {
  return getJson<RepoPluginTabsPayload>(`/api/v1/app/repositories/${repositoryId}/plugin_tabs`)
}

export function useRepositoryTabs(repositoryId: string | number) {
  return useQuery({
    queryKey: ["repositories", String(repositoryId), "plugin_tabs"],
    queryFn: () => fetchRepoPluginTabs(repositoryId),
    enabled: String(repositoryId).length > 0,
    staleTime: 30_000
  })
}
