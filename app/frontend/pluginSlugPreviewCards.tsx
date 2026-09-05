import { lazy, type ComponentType } from "react"

// Discovers plugin-supplied DOC-<id>-style slug hover/preview card
// components. A plugin registers the slug prefix it owns (e.g. "DOC")
// purely by naming its file <PREFIX>.<Name>.tsx under
// plugins/<name>/app/frontend/slugPreviewCards/ -- core never lists which
// plugin owns which prefix anywhere. SlugHoverCard.tsx (core) only knows
// kind: "job" | "epic" | "plugin"; for "plugin" it passes through the
// prefix parsed directly from the slug text and resolves it here without
// ever importing plugin code directly -- physically removing the plugin
// just empties this glob, it does not break the build.
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
    const match = path.match(/^\.\.\/\.\.\/plugins\/[^/]+\/app\/frontend\/slugPreviewCards\/([A-Z0-9]+)\.[^/.]+\.tsx$/)
    if (!match) return []

    return [ match[1], loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType<PluginSlugPreviewCardProps>>()

export function pluginSlugPreviewCardPrefixes() {
  return Object.keys(componentLoaders).sort()
}

export function pluginSlugPreviewCardComponentForPrefix(prefix: string | null | undefined) {
  if (!prefix) return null
  const cached = componentCache.get(prefix)
  if (cached) return cached

  const loader = componentLoaders[prefix]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin slug preview card for prefix ${prefix} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(prefix, Component)
  return Component
}
