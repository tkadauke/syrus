import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { useLocation, useParams } from "react-router-dom"
import { fetchRepoPluginTabs } from "./api/repoPluginTabs"
import { REPOSITORY_TABS_STALE_TIME } from "./components/RepositoryPageShell"
import { Notice, Page, PageHeading, Text } from "./components/ui"
import { withPluginErrorBoundary } from "./components/PluginErrorBoundary"
import { useT } from "./hooks/useT"
import { loadPluginModule } from "./i18n"
import "./builtInPluginContributions"
import { getPluginContribution, getPluginContributions, pluginContributionLoader } from "./pluginContributionRegistry"

type PluginModule = {
  default?: ComponentType
}

const componentCache = new Map<string, ComponentType>()

export function pluginRepoComponentKeys() {
  return getPluginContributions<PluginModule>("repo_page_tab")
    .map(({ pluginName, key }) => `${pluginName}/${key}`)
    .sort()
}

export function pluginRepoComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const [pluginName, componentKey] = key.split("/", 2)
  const contribution = getPluginContribution<PluginModule>("repo_page_tab", pluginName, componentKey)
  if (!contribution) return null

  const Component = lazy(async () => {
    const mod = await loadPluginModule(pluginName, pluginContributionLoader(contribution))
    if (!mod.default) throw new Error(`Plugin repo tab component ${key} has no default export`)
    return { default: mod.default }
  })
  const IsolatedComponent = withPluginErrorBoundary(pluginName, Component)
  componentCache.set(key, IsolatedComponent)
  return IsolatedComponent
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
    staleTime: REPOSITORY_TABS_STALE_TIME
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
    <Suspense
      fallback={
        <Page.Root size="narrow">
          <Notice>{t("common:loading")}</Notice>
        </Page.Root>
      }
    >
      <Component />
    </Suspense>
  )
}
