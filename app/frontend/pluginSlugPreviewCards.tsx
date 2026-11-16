import { lazy, type ComponentType } from "react"
import { loadPluginModule } from "./i18n"
import "./builtInPluginContributions"
import { getPluginContributions, pluginContributionLoader, type PluginContribution } from "./pluginContributionRegistry"

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

const componentCache = new Map<string, ComponentType<PluginSlugPreviewCardProps>>()

function contributionForPrefix(prefix: string): PluginContribution<PluginModule> | undefined {
  return getPluginContributions<PluginModule>("slug_preview_card").find(({ key }) => key.split(".", 1)[0] === prefix)
}

export function pluginSlugPreviewCardPrefixes() {
  return getPluginContributions<PluginModule>("slug_preview_card").map(({ key }) => key.split(".", 1)[0]).sort()
}

export function pluginSlugPreviewCardComponentForPrefix(prefix: string | null | undefined) {
  if (!prefix) return null
  const cached = componentCache.get(prefix)
  if (cached) return cached

  const contribution = contributionForPrefix(prefix)
  if (!contribution) return null

  const Component = lazy(async () => {
    const mod = await loadPluginModule(contribution.pluginName, pluginContributionLoader(contribution))
    if (!mod.default) throw new Error(`Plugin slug preview card for prefix ${prefix} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(prefix, Component)
  return Component
}
