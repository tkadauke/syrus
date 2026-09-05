import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ComponentType } from "react"
import { matchPath, useLocation } from "react-router-dom"
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

/**
 * Resolves the plugin sidebar page that owns the current URL, if any.
 *
 * Paths are matched with React Router's own matcher rather than string
 * prefixes, because a declared path can carry parameters --
 * `/repositories/:repository_id/scheduled_tasks` cannot be matched by
 * comparing text, and quietly never matched before.
 */
/** Every path plugins have claimed, for registering real routes. */
export function usePluginSidebarPaths({ enabled }: { enabled: boolean }) {
  const pages = useQuery({
    queryKey: ["sidebar", "plugin_pages"],
    queryFn: fetchSidebarPluginPages,
    staleTime: 30_000,
    // Gated on being signed in, exactly as AppChromeV2 gates the same query:
    // a pre-auth page must not call an app API, and has no plugin pages to
    // route to anyway.
    enabled
  })

  return (pages.data?.pages ?? []).flatMap((page) =>
    Array.from(page.paths ?? []).map((path) => ({ path, section: page.section }))
  )
}

export function usePluginSidebarPage() {
  const location = useLocation()
  const normalizedPath = location.pathname.replace(/^\/app-shell/, "") || "/"
  const pages = useQuery({
    queryKey: ["sidebar", "plugin_pages"],
    queryFn: fetchSidebarPluginPages,
    staleTime: 30_000
  })

  // `pages?.` and not just `data?.`: a response without the key at all must
  // read as "no plugin claims this URL", not throw inside the catch-all and
  // take the whole shell down with it.
  const page = pages.data?.pages?.find((candidate) =>
    candidate.paths.some((path) => matchPath({ path, end: false }, normalizedPath) !== null)
  )

  return { isPending: pages.isPending, page, Component: pluginSidebarComponentFor(page?.component) }
}

export function PluginSidebarPageRoute() {
  const { t } = useT("nav")
  const { isPending, page, Component } = usePluginSidebarPage()

  if (isPending) {
    return <main className="p-6 text-sm text-gray-600 dark:text-gray-300">{t("sidebar_pages.loading")}</main>
  }

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
