export type PluginContributionKind =
  "workspace_tab" | "admin_page" | "sidebar_page" | "repo_page_tab" | "slug_preview_card" | "review_contribution" | "review_annotation" | "ui_slot"

export type PluginContribution<T = unknown> = {
  pluginName: string
  key: string
  value: T | (() => Promise<T>)
}

export type PluginContributionChange = {
  kind: PluginContributionKind
  pluginName: string
  key: string
}

type PluginContributionListener = (change: PluginContributionChange) => void

const contributions = new Map<PluginContributionKind, Map<string, PluginContribution>>()
const listeners = new Set<PluginContributionListener>()

function contributionId(pluginName: string, key: string) {
  return `${pluginName}/${key}`
}

export function registerPluginContribution<T>(kind: PluginContributionKind, pluginName: string, key: string, value: T | (() => Promise<T>)) {
  let contributionsForKind = contributions.get(kind)
  if (!contributionsForKind) {
    contributionsForKind = new Map()
    contributions.set(kind, contributionsForKind)
  }

  const id = contributionId(pluginName, key)
  if (contributionsForKind.has(id)) return

  contributionsForKind.set(id, { pluginName, key, value })
  const change = { kind, pluginName, key }
  listeners.forEach((listener) => listener(change))
}

export function getPluginContributions<T>(kind: PluginContributionKind): ReadonlyArray<PluginContribution<T>> {
  return Array.from(contributions.get(kind)?.values() ?? []) as Array<PluginContribution<T>>
}

export function getPluginContribution<T>(kind: PluginContributionKind, pluginName: string, key: string): PluginContribution<T> | undefined {
  return contributions.get(kind)?.get(contributionId(pluginName, key)) as PluginContribution<T> | undefined
}

export function pluginContributionLoader<T>(contribution: PluginContribution<T>): () => Promise<T> {
  if (typeof contribution.value === "function") return contribution.value as () => Promise<T>
  return async () => contribution.value as T
}

export function subscribeToPluginContributions(listener: PluginContributionListener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}
