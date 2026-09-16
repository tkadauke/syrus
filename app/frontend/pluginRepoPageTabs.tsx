import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { useLocation, useParams } from "react-router-dom"
import { fetchRepoPluginTabs } from "./api/repoPluginTabs"
import { Notice, Page, PageHeading, Text } from "./components/ui"
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
    return (
      <Page.Root size="narrow">
        <Notice>{t("common:loading")}</Notice>
      </Page.Root>
    )
  }

  const tab = tabs.data?.tabs.find((candidate) => candidate.paths.some((path) => path === normalizedPath))
  const Component = pluginRepoComponentFor(tab?.component)

  if (!tab || !Component) {
    return (
      <Page.Root size="narrow">
        <Page.Header>
          <PageHeading>{t("plugin_repo_tabs.unavailable_heading")}</PageHeading>
          <Text>{t("plugin_repo_tabs.unavailable_body")}</Text>
        </Page.Header>
      </Page.Root>
    )
  }

  return (
    <Suspense fallback={<Page.Root size="narrow"><Notice>{t("common:loading")}</Notice></Page.Root>}>
      <Component />
    </Suspense>
  )
}
