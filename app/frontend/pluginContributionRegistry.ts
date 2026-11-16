export const pluginContributionKinds = ["workspace_tab", "admin_page", "sidebar_page"] as const

export type PluginContributionKind = (typeof pluginContributionKinds)[number]
export type PluginContribution<T> = T | (() => Promise<T>)

export type RegisteredPluginContribution<T = unknown> = {
  pluginName: string
  key: string
  contribution: PluginContribution<T>
}

type Listener = () => void

const contributions = new Map<PluginContributionKind, Map<string, RegisteredPluginContribution>>()
const listeners = new Set<Listener>()

function registryKey(pluginName: string, key: string) {
  return `${pluginName}\0${key}`
}

export function registerPluginContribution<T>(kind: PluginContributionKind, pluginName: string, key: string, contribution: PluginContribution<T>) {
  let entries = contributions.get(kind)
  if (!entries) {
    entries = new Map()
    contributions.set(kind, entries)
  }

  const id = registryKey(pluginName, key)
  if (entries.has(id)) return

  entries.set(id, { pluginName, key, contribution })
  listeners.forEach((listener) => listener())
}

export function getPluginContributions<T>(kind: PluginContributionKind): RegisteredPluginContribution<T>[] {
  return Array.from(contributions.get(kind)?.values() ?? []) as RegisteredPluginContribution<T>[]
}

export function getPluginContribution<T>(kind: PluginContributionKind, pluginName: string, key: string): PluginContribution<T> | undefined {
  return contributions.get(kind)?.get(registryKey(pluginName, key))?.contribution as PluginContribution<T> | undefined
}

export function subscribeToPluginContributions(listener: Listener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function loadPluginContribution<T>(contribution: PluginContribution<T>): Promise<T> {
  return typeof contribution === "function" ? (contribution as () => Promise<T>)() : Promise.resolve(contribution)
}
