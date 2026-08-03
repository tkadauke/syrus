import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { fetchAdminPlugins, type AdminPlugin, type AdminPluginExtensionPoint } from "../api/adminPlugins"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

export function AdminPlugins() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_plugins"))
  const plugins = useQuery({
    queryKey: ["admin", "plugins"],
    queryFn: fetchAdminPlugins
  })

  return (
    <main aria-label={t("plugins.aria_plugins")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("plugins.heading")}</h1>
      </header>

      {plugins.isPending ? <PanelMessage>{t("plugins.loading")}</PanelMessage> : null}
      {plugins.isError ? <PanelMessage tone="error">{errorMessage(plugins.error, t("plugins.error_load"))}</PanelMessage> : null}
      {plugins.isSuccess ? <PluginsView plugins={plugins.data.plugins} /> : null}
    </main>
  )
}

function PluginsView({ plugins }: { plugins: AdminPlugin[] }) {
  const { t } = useT("admin")
  if (plugins.length === 0) {
    return (
      <section className="rounded border border-dashed border-gray-300 bg-white p-8 text-center dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("plugins.no_plugins_heading")}</h2>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{t("plugins.no_plugins_body")}</p>
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

  return (
    <article className="rounded border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="break-words text-base font-semibold text-gray-900 dark:text-gray-100">{plugin.name}</h2>
            <span className="rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{plugin.version}</span>
            <StatusBadge status={plugin.enabled ? "enabled" : "disabled"} label={plugin.enabled ? t("plugins.enabled") : t("plugins.disabled")} />
          </div>
          {plugin.description ? <p className="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">{plugin.description}</p> : null}
        </div>
        <PluginMetadata plugin={plugin} />
      </div>

      {plugin.extension_points.length > 0 ? (
        <div className="mt-4 overflow-x-auto">
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
        <p className="mt-4 text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_extension_points")}</p>
      )}
    </article>
  )
}

function PluginMetadata({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const rows = [
    plugin.author ? [t("plugins.author"), plugin.author] : null,
    plugin.homepage ? [t("plugins.homepage"), plugin.homepage] : null,
    plugin.source ? [t("plugins.source"), plugin.source] : null
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
