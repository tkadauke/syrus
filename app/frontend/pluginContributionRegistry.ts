export type PluginContributionKind =
  | "workspace_tab"
  | "admin_page"
  | "sidebar_page"
  | "repo_page_tab"
  | "slug_preview_card"
  | "review_contribution"
  | "review_annotation"
  | "ui_slot"
  | "tool_card"
  | "chat_message_renderer"
  | "artifact_renderer"
  | "agent_provider_connect_panel"
  | "runtime_session_view"

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
const preloaders = new Map<string, () => Promise<void>>()
let generation = 0

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
  generation += 1
  const change = { kind, pluginName, key }
  listeners.forEach((listener) => listener(change))
}

export function getPluginContributions<T>(kind: PluginContributionKind): ReadonlyArray<PluginContribution<T>> {
  return Array.from(contributions.get(kind)?.values() ?? []) as Array<PluginContribution<T>>
}

export function getEagerPluginContributions<T>(kind: PluginContributionKind): ReadonlyArray<PluginContribution<T> & { value: T }> {
  return getPluginContributions<T>(kind).filter(
    (contribution): contribution is PluginContribution<T> & { value: T } => typeof contribution.value !== "function"
  )
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

export function pluginContributionGeneration() {
  return generation
}

export function registerPluginContributionPreloader(pluginName: string, preloader: () => Promise<void>) {
  if (!preloaders.has(pluginName)) preloaders.set(pluginName, preloader)
}

export async function preloadPluginContributions(pluginNames: readonly string[]) {
  await Promise.all(pluginNames.map((pluginName) => preloaders.get(pluginName)?.()))
}

export function pluginContributionsRequirePreload(pluginNames: readonly string[]) {
  return pluginNames.some((pluginName) => preloaders.has(pluginName))
}
