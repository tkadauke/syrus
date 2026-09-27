import { lazy, Suspense, useEffect, useLayoutEffect, useMemo, useRef, useState, type ComponentType, type ReactNode } from "react"
import { ChevronIcon } from "./components/ChevronIcon"

type PluginModule = {
  default?: ComponentType<Record<string, unknown>>
}

export type UiSlotPanel = {
  id: string
  component: string
  order: number
  props?: Record<string, unknown>
  // Set only for `.tab` slots, where a panel is rendered as an extra tab.
  key?: string
  label?: string
  label_key?: string
}

const corePanelModules = import.meta.glob<PluginModule>("./ui_slots/*.tsx")
const pluginPanelModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/ui_slots/*.tsx")

const componentLoaders = Object.fromEntries(
  [
    ...Object.entries(corePanelModules).map(([path, loader]) => {
      const match = path.match(/^\.\/ui_slots\/([^/.]+)\.tsx$/)
      if (!match) return []

      return [ `core/${match[1]}`, loader ]
    }),
    ...Object.entries(pluginPanelModules).map(([path, loader]) => {
      const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/ui_slots\/([^/.]+)\.tsx$/)
      if (!match) return []

      return [ `${match[1]}/${match[2]}`, loader ]
    })
  ].filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
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

// Renders whatever core or plugin code contributed to one slot on a page. A panel
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

type UiSlotCarouselLabels = {
  region: string
  position: (index: number, count: number) => string
  previous: string
  next: string
}

export function PluginUiSlotCarousel({ labels, panels, props }: { labels: UiSlotCarouselLabels; panels: UiSlotPanel[] | undefined; props?: Record<string, unknown> }) {
  const orderedPanels = useMemo(
    () => (panels || [])
      .map((panel, index) => ({ panel, index }))
      .sort((left, right) => left.panel.order - right.panel.order || left.index - right.index)
      .map(({ panel }) => panel),
    [panels]
  )
  const renderablePanels = useMemo(
    () => orderedPanels.filter((panel) => pluginUiSlotComponentFor(panel.component)),
    [orderedPanels]
  )
  const [activeId, setActiveId] = useState<string | null>(null)
  const [visibleIds, setVisibleIds] = useState<string[]>([])

  useEffect(() => {
    setVisibleIds((current) => current.filter((id) => renderablePanels.some((panel) => panel.id === id)))
  }, [renderablePanels])

  useEffect(() => {
    if (visibleIds.length === 0) {
      if (activeId !== null) setActiveId(null)
      return
    }
    if (!activeId || !visibleIds.includes(activeId)) setActiveId(visibleIds[0])
  }, [activeId, visibleIds])

  if (renderablePanels.length === 0) return null

  const activeIndex = activeId ? visibleIds.indexOf(activeId) : -1
  const showControls = visibleIds.length > 1 && activeIndex >= 0

  function setPanelVisible(id: string, visible: boolean) {
    setVisibleIds((current) => {
      const hasId = current.includes(id)
      if (visible && !hasId) return renderablePanels.filter((panel) => panel.id === id || current.includes(panel.id)).map((panel) => panel.id)
      if (!visible && hasId) return current.filter((currentId) => currentId !== id)
      return current
    })
  }

  return (
    <section aria-label={labels.region} className="space-y-2">
      {showControls ? (
        <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-text-secondary">
          <span className="font-medium" role="status">{labels.position(activeIndex + 1, visibleIds.length)}</span>
          <div className="flex items-center gap-1">
            <button
              aria-label={labels.previous}
              className="inline-flex h-7 w-7 items-center justify-center rounded border border-border bg-surface hover:bg-surface-muted"
              onClick={() => setActiveId(visibleIds[(activeIndex - 1 + visibleIds.length) % visibleIds.length])}
              type="button"
            >
              <ChevronIcon className="h-4 w-4 rotate-180" />
            </button>
            <button
              aria-label={labels.next}
              className="inline-flex h-7 w-7 items-center justify-center rounded border border-border bg-surface hover:bg-surface-muted"
              onClick={() => setActiveId(visibleIds[(activeIndex + 1) % visibleIds.length])}
              type="button"
            >
              <ChevronIcon className="h-4 w-4" />
            </button>
          </div>
        </div>
      ) : null}
      {renderablePanels.map((panel) => {
        const Component = pluginUiSlotComponentFor(panel.component)
        if (!Component) return null

        return (
          <UiSlotCarouselPanel
            active={panel.id === activeId || (activeId === null && panel.id === renderablePanels[0]?.id)}
            key={panel.id}
            onVisibleChange={(visible) => setPanelVisible(panel.id, visible)}
          >
            <Suspense fallback={null}>
              <Component {...(props || {})} {...(panel.props || {})} />
            </Suspense>
          </UiSlotCarouselPanel>
        )
      })}
    </section>
  )
}

function UiSlotCarouselPanel({ active, children, onVisibleChange }: { active: boolean; children: ReactNode; onVisibleChange: (visible: boolean) => void }) {
  const ref = useRef<HTMLDivElement | null>(null)

  useLayoutEffect(() => {
    const node = ref.current
    if (!node) return

    const report = () => onVisibleChange(node.childElementCount > 0)
    report()
    const observer = new MutationObserver(report)
    observer.observe(node, { childList: true })
    return () => observer.disconnect()
  }, [onVisibleChange])

  return (
    <div className={active ? "" : "hidden"} ref={ref}>
      {children}
    </div>
  )
}
