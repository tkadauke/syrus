import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { useLocation } from "react-router-dom"
import { fetchSidebarPluginPages } from "./api/sidebarPages"
import { useT } from "./hooks/useT"

type PluginModule = {
  default?: ComponentType
}

const routeModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/routes/*.tsx")

const componentLoaders = Object.fromEntries(
  Object.entries(routeModules).map(([path, loader]) => {
    const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/routes\/([^/.]+)\.tsx$/)
    if (!match) return []

    return [ `${match[1]}/${match[2]}`, loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType>()

export function pluginSidebarComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin sidebar component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}

export function PluginSidebarPageRoute() {
  const { t } = useT("nav")
  const location = useLocation()
  const normalizedPath = location.pathname.replace(/^\/app-shell/, "") || "/"
  const pages = useQuery({
    queryKey: ["sidebar", "plugin_pages"],
    queryFn: fetchSidebarPluginPages,
    staleTime: 30_000
  })

  if (pages.isPending) {
    return <main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("sidebar_pages.loading")}</main>
  }

  const page = pages.data?.pages.find((candidate) => candidate.paths.some((path) => path === normalizedPath || normalizedPath.startsWith(`${path}/`)))
  const Component = pluginSidebarComponentFor(page?.component)

  if (!page || !Component) {
    return (
      <main className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-semibold text-gray-900 dark:text-gray-100">{t("sidebar_pages.unavailable_heading")}</h1>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{t("sidebar_pages.unavailable_body")}</p>
      </main>
    )
  }

  return (
    <Suspense fallback={<main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("sidebar_pages.loading")}</main>}>
      <Component />
    </Suspense>
  )
}
