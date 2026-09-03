import { lazy, Suspense, type ComponentType } from "react"

type PluginModule = {
  default?: ComponentType<Record<string, unknown>>
}

export type UiSlotPanel = {
  id: string
  component: string
  order: number
  props?: Record<string, unknown>
}

const panelModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/ui_slots/*.tsx")

const componentLoaders = Object.fromEntries(
  Object.entries(panelModules).map(([path, loader]) => {
    const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/ui_slots\/([^/.]+)\.tsx$/)
    if (!match) return []

    return [ `${match[1]}/${match[2]}`, loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType<Record<string, unknown>>>()

export function pluginUiSlotComponentKeys() {
  return Object.keys(componentLoaders).sort()
}

export function pluginUiSlotComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin UI slot component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}

// Renders whatever plugins contributed to one slot on a core page. A panel
// whose component is missing from the bundle is skipped rather than throwing,
// so a stale server-side registration cannot blank the page around it.
export function PluginUiSlot({ panels, props }: { panels: UiSlotPanel[] | undefined; props?: Record<string, unknown> }) {
  if (!panels || panels.length === 0) return null

  return (
    <>
      {panels.map((panel) => {
        const Component = pluginUiSlotComponentFor(panel.component)
        if (!Component) return null

        return (
          <Suspense key={panel.id} fallback={null}>
            <Component {...(props || {})} {...(panel.props || {})} />
          </Suspense>
        )
      })}
    </>
  )
}
