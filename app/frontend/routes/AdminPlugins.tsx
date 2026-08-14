import { useMutation, useQuery } from "@tanstack/react-query"
import { useEffect, useState, type ReactNode } from "react"
import { disableAdminPlugin, enableAdminPlugin, fetchAdminPlugins, type AdminPlugin, type AdminPluginExtensionPoint } from "../api/adminPlugins"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import * as pageReload from "../lib/pageReload"

const SEARCH_DEBOUNCE_MS = 300

export function AdminPlugins() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_plugins"))
  const [search, setSearch] = useState("")
  const [debouncedSearch, setDebouncedSearch] = useState("")

  useEffect(() => {
    const handle = setTimeout(() => setDebouncedSearch(search), SEARCH_DEBOUNCE_MS)
    return () => clearTimeout(handle)
  }, [search])

  const plugins = useQuery({
    queryKey: ["admin", "plugins", debouncedSearch],
    queryFn: () => fetchAdminPlugins(debouncedSearch),
    placeholderData: (previousData) => previousData
  })

  return (
    <main aria-label={t("plugins.aria_plugins")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("plugins.heading")}</h1>
      </header>

      <input
        aria-label={t("plugins.search_aria")}
        className="w-full max-w-sm rounded border border-gray-300 px-3 py-1.5 text-sm text-gray-900 placeholder:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500"
        onChange={(e) => setSearch(e.target.value)}
        placeholder={t("plugins.search_placeholder")}
        type="search"
        value={search}
      />

      {plugins.isPending ? <PanelMessage>{t("plugins.loading")}</PanelMessage> : null}
      {plugins.isError ? <PanelMessage tone="error">{errorMessage(plugins.error, t("plugins.error_load"))}</PanelMessage> : null}
      {plugins.isSuccess ? <PluginsView isFiltered={debouncedSearch.trim().length > 0} plugins={plugins.data.plugins} /> : null}
    </main>
  )
}

function PluginsView({ plugins, isFiltered }: { plugins: AdminPlugin[]; isFiltered: boolean }) {
  const { t } = useT("admin")
  if (plugins.length === 0) {
    return (
      <section className="rounded border border-dashed border-gray-300 bg-white p-8 text-center dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
          {isFiltered ? t("plugins.no_results_heading") : t("plugins.no_plugins_heading")}
        </h2>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">
          {isFiltered ? t("plugins.no_results_body") : t("plugins.no_plugins_body")}
        </p>
      </section>
    )
  }

  return (
    <section aria-label={t("plugins.list_aria")} className="space-y-4">
      {plugins.map((plugin) => <PluginCard key={plugin.name} plugin={plugin} />)}
    </section>
  )
}

function PluginCard({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const toggle = useMutation({
    mutationFn: () => plugin.enabled ? disableAdminPlugin(plugin.name) : enableAdminPlugin(plugin.name),
    onSuccess: () => {
      pageReload.reloadPage()
    }
  })
  const disableBlockers = plugin.disable_blockers || []
  const disableBlocked = plugin.enabled && disableBlockers.length > 0

  let disableTooltip: string | undefined
  if (plugin.enabled && !plugin.disableable) {
    disableTooltip = t("plugins.required")
  } else if (disableBlocked) {
    if (disableBlockers.length === 1) {
      disableTooltip = `${disableBlockers[0].label}: ${disableBlockers[0].count}`
    } else {
      disableTooltip = t("plugins.disable_blocked_tooltip_many")
    }
  }

  return (
    <article className="rounded border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="break-words text-base font-semibold text-gray-900 dark:text-gray-100">{plugin.display_name || plugin.name}</h2>
            {plugin.display_name && plugin.display_name !== plugin.name ? <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{plugin.name}</span> : null}
            <span className="rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{plugin.version}</span>
            <StatusBadge status={plugin.enabled ? "enabled" : "disabled"} label={plugin.enabled ? t("plugins.enabled") : t("plugins.disabled")} />
            {!plugin.disableable ? <StatusBadge status="required" label={t("plugins.required")} /> : null}
          </div>
          {plugin.description ? <p className="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">{plugin.description}</p> : null}
          <div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            {plugin.category ? <span>{t("plugins.category")}: <span className="font-mono">{plugin.category}</span></span> : null}
            <span>{t("plugins.default_state")}: {plugin.default_enabled ? t("plugins.enabled") : t("plugins.disabled")}</span>
          </div>
          {toggle.isError ? <p className="mt-2 text-sm text-red-700 dark:text-red-300">{errorMessage(toggle.error, t("plugins.error_toggle"))}</p> : null}
        </div>
        <div className="flex shrink-0 flex-col items-start gap-3 sm:items-end">
          <span title={disableTooltip}>
            <button
              className="inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
              disabled={toggle.isPending || (plugin.enabled && (!plugin.disableable || disableBlocked))}
              onClick={() => toggle.mutate()}
              type="button"
            >
              {toggle.isPending ? t("plugins.saving") : plugin.enabled ? t("plugins.disable") : t("plugins.enable")}
            </button>
          </span>
          <PluginMetadata plugin={plugin} />
        </div>
      </div>

      {disableBlocked ? (
        <details className="mt-4">
          <summary className="cursor-pointer select-none text-xs font-medium uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
            {t("plugins.usage_heading")}
          </summary>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-amber-700 dark:text-amber-300">
            {disableBlockers.map((blocker) => <li key={`${blocker.kind}-${blocker.label}`}>{blocker.label}: {blocker.count}</li>)}
          </ul>
        </details>
      ) : null}

      <details className="mt-4">
        <summary className="cursor-pointer select-none text-xs font-medium uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
          {t("plugins.extension_points_heading")}
        </summary>
        {plugin.extension_points.length > 0 ? (
          <div className="mt-2 overflow-x-auto">
            <table className="min-w-full text-left text-sm">
              <thead className="border-b border-gray-200 text-xs uppercase text-gray-500 dark:border-gray-800 dark:text-gray-400">
                <tr>
                  <th className="py-2 pr-4 font-medium">{t("plugins.col_extension_point")}</th>
                  <th className="py-2 pr-4 font-medium">{t("plugins.col_class")}</th>
                  <th className="py-2 font-medium">{t("plugins.col_availability")}</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
                {plugin.extension_points.map((extension) => <ExtensionPointRow extension={extension} key={`${extension.extension_point}-${extension.class_name}`} />)}
              </tbody>
            </table>
          </div>
        ) : (
          <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_extension_points")}</p>
        )}
      </details>
    </article>
  )
}

function PluginMetadata({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const rows = [
    plugin.author ? [t("plugins.author"), plugin.author] : null,
    plugin.homepage ? [t("plugins.homepage"), plugin.homepage] : null
  ].filter(Boolean) as string[][]

  if (rows.length === 0) return null

  return (
    <dl className="grid shrink-0 gap-1 text-xs sm:max-w-sm">
      {rows.map(([label, value]) => (
        <div className="grid gap-0.5" key={label}>
          <dt className="font-medium uppercase text-gray-500 dark:text-gray-400">{label}</dt>
          <dd className="break-all text-gray-700 dark:text-gray-200">{value}</dd>
        </div>
      ))}
    </dl>
  )
}

function ExtensionPointRow({ extension }: { extension: AdminPluginExtensionPoint }) {
  const { t } = useT("admin")
  const count = extension.availability.configured_count

  return (
    <tr>
      <td className="py-3 pr-4 font-mono text-xs text-gray-700 dark:text-gray-200">{extensionPointLabel(extension.extension_point, t)}</td>
      <td className="py-3 pr-4 font-mono text-xs text-gray-700 dark:text-gray-200">{extension.class_name}</td>
      <td className="py-3">
        <div className="flex flex-wrap items-center gap-2">
          <StatusBadge label={extension.availability.label} status={extension.availability.status} />
          {typeof count === "number" ? <span className="text-xs text-gray-500 dark:text-gray-400">{t("plugins.configured_repos", { count })}</span> : null}
          {extension.availability.detail ? <span className="text-xs text-red-700 dark:text-red-300">{extension.availability.detail}</span> : null}
        </div>
      </td>
    </tr>
  )
}

function StatusBadge({ status, label }: { status: string; label: string }) {
  const tone = statusTone(status)
  return <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone}`}>{label}</span>
}

function statusTone(status: string) {
  if (["available", "configured", "enabled", "registered"].includes(status)) return "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
  if (status === "required") return "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300"
  if (["disabled", "not_configured"].includes(status)) return "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"
  if (status === "error") return "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
  return "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
}

function extensionPointLabel(point: string, t: (key: string, opts?: Record<string, unknown>) => string) {
  return t(`plugins.extension_points.${point}`, { defaultValue: point })
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
