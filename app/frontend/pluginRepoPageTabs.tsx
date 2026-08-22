import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { useLocation, useParams } from "react-router-dom"
import { fetchRepoPluginTabs } from "./api/repoPluginTabs"
import { useT } from "./hooks/useT"

type PluginModule = {
  default?: ComponentType
}

const routeModules = import.meta.glob<PluginModule>("../../plugins/*/app/frontend/repo_tabs/*.tsx")

const componentLoaders = Object.fromEntries(
  Object.entries(routeModules).map(([path, loader]) => {
    const match = path.match(/^\.\.\/\.\.\/plugins\/([^/]+)\/app\/frontend\/repo_tabs\/([^/.]+)\.tsx$/)
    if (!match) return []

    return [ `${match[1]}/${match[2]}`, loader ]
  }).filter((entry): entry is [ string, () => Promise<PluginModule> ] => entry.length === 2)
)

const componentCache = new Map<string, ComponentType>()

export function pluginRepoComponentKeys() {
  return Object.keys(componentLoaders).sort()
}

export function pluginRepoComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin repo tab component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}

export function PluginRepoPageTabRoute() {
  const { t } = useT("nav")
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const normalizedPath = location.pathname.replace(/^\/app-shell/, "") || "/"
  const tabs = useQuery({
    queryKey: ["repositories", repositoryId, "plugin_tabs"],
    queryFn: () => fetchRepoPluginTabs(repositoryId),
    enabled: repositoryId.length > 0,
    staleTime: 30_000
  })

  if (tabs.isPending) {
    return <main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("common:loading")}</main>
  }

  const tab = tabs.data?.tabs.find((candidate) => candidate.paths.some((path) => path === normalizedPath))
  const Component = pluginRepoComponentFor(tab?.component)

  if (!tab || !Component) {
    return (
      <main className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-semibold text-gray-900 dark:text-gray-100">{t("plugin_repo_tabs.unavailable_heading")}</h1>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{t("plugin_repo_tabs.unavailable_body")}</p>
      </main>
    )
  }

  return (
    <Suspense fallback={<main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("common:loading")}</main>}>
      <Component />
    </Suspense>
  )
}
