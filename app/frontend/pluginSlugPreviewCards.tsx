import { lazy, type ComponentType } from "react"

// Discovers plugin-supplied DOC-<id>-style slug hover/preview card
// components, the same import.meta.glob-based convention
// pluginWorkspaceTabs.tsx/pluginUiSlots.tsx use: a plugin drops its card
// component at plugins/<name>/app/frontend/slugPreviewCards/<Name>.tsx,
// keyed here as "<name>/<Name>", and SlugHoverCard.tsx (core) resolves a
// slug `kind` to one of these keys without ever importing plugin code
// directly -- physically removing the plugin just empties this glob, it
// does not break the build.
export type PluginSlugPreviewCardProps = {
  id: number
  compact?: boolean
}

type PluginModule = {
  default?: ComponentType<PluginSlugPreviewCardProps>
}

const slugPreviewCardModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/slugPreviewCards/*.tsx")

const componentLoaders = Object.fromEntries(
  Object.entries(slugPreviewCardModules).map(([path, loader]) => {
    const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/slugPreviewCards\/([^/.]+)\.tsx$/)
    if (!match) return []

    return [ `${match[1]}/${match[2]}`, loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType<PluginSlugPreviewCardProps>>()

export function pluginSlugPreviewCardComponentKeys() {
  return Object.keys(componentLoaders).sort()
}

export function pluginSlugPreviewCardComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin slug preview card component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}
