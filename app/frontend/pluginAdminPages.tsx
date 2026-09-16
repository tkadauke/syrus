import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { matchPath, useLocation } from "react-router-dom"
import { fetchAdminPluginPages } from "./api/adminPluginPages"
import { Notice, Page, PageHeading, Text } from "./components/ui"
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

export function pluginAdminComponentKeys() {
  return Object.keys(componentLoaders).sort()
}

export function pluginAdminComponentFor(key: string | null | undefined) {
  if (!key) return null
  const cached = componentCache.get(key)
  if (cached) return cached

  const loader = componentLoaders[key]
  if (!loader) return null

  const Component = lazy(async () => {
    const mod = await loader()
    if (!mod.default) throw new Error(`Plugin admin component ${key} has no default export`)
    return { default: mod.default }
  })
  componentCache.set(key, Component)
  return Component
}

/**
 * Resolves the plugin admin page that owns the current URL, if any.
 *
 * Paths are matched with React Router's own matcher rather than string
 * equality, mirroring `usePluginSidebarPage` -- a declared path can carry
 * parameters, which cannot be matched by comparing text.
 */
export function usePluginAdminPage() {
  const location = useLocation()
  const normalizedPath = location.pathname.replace(/^\/app-shell/, "") || "/"
  const pages = useQuery({
    queryKey: ["admin", "plugin_pages"],
    queryFn: fetchAdminPluginPages,
    staleTime: 30_000
  })

  const page = pages.data?.pages.find((candidate) =>
    candidate.paths.some((path) => matchPath({ path, end: false }, normalizedPath) !== null)
  )

  return { isPending: pages.isPending, page, Component: pluginAdminComponentFor(page?.component) }
}

export function PluginAdminPageRoute() {
  const { t } = useT("admin")
  const { isPending, page, Component } = usePluginAdminPage()

  if (isPending) {
    return (
      <Page.Root size="narrow">
        <Notice>{t("loading")}</Notice>
      </Page.Root>
    )
  }

  if (!page || !Component) {
    return (
      <Page.Root size="narrow">
        <Page.Header>
          <PageHeading>{t("plugin_pages.unavailable_heading")}</PageHeading>
          <Text>{t("plugin_pages.unavailable_body")}</Text>
        </Page.Header>
      </Page.Root>
    )
  }

  return (
    <Suspense fallback={<Page.Root size="narrow"><Notice>{t("loading")}</Notice></Page.Root>}>
      <Component />
    </Suspense>
  )
}
