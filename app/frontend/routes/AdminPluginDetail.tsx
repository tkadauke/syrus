import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { fetchAdminPlugin, enableAdminPlugin, disableAdminPlugin, type AdminPlugin, type AdminPluginDetail as AdminPluginDetailPayload, type AdminPluginLink, type AdminPluginMetric } from "../api/adminPlugins"
import { Button, buttonClasses } from "../components/Button"
import { PageHeading, SectionHeading } from "../components/Heading"
import { Surface } from "../components/ui"
import { LinkText } from "../components/ui/LinkText"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Markdown } from "../lib/Markdown"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { refreshSidebarPluginPages } from "../lib/sidebarPluginPagesCache"
import { ExtensionPointRow, StatusBadge } from "./AdminPlugins"

export function AdminPluginDetail() {
  const { name = "" } = useParams()
  const { t } = useT("admin")
  const location = useLocation()
  usePageTitle(t("page_title_plugin_detail"))
  const prefix = routePrefix(location.pathname)

  const plugin = useQuery({
    queryKey: ["admin", "plugins", name],
    queryFn: () => fetchAdminPlugin(name),
    enabled: name.length > 0
  })

  return (
    <main aria-label={t("plugins.detail_aria")} className="mx-auto max-w-6xl space-y-6 p-6">
      <LinkText to={`${prefix}/admin/plugins`}>{t("plugins.back_to_plugins")}</LinkText>
      {plugin.isPending ? <PanelMessage>{t("plugins.detail_loading")}</PanelMessage> : null}
      {plugin.isError ? <PanelMessage tone="error">{errorMessage(plugin.error, t("plugins.detail_error_load"))}</PanelMessage> : null}
      {plugin.isSuccess ? <PluginDetailView plugin={plugin.data} /> : null}
    </main>
  )
}

function PluginDetailView({ plugin }: { plugin: AdminPluginDetailPayload }) {
  const { t } = useT("admin")

  return (
    <>
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div className="min-w-0">
            <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
            <div className="mt-2 flex flex-wrap items-center gap-3">
              {plugin.icon_url ? <img alt="" aria-hidden="true" className="h-10 w-10 shrink-0" src={plugin.icon_url} /> : null}
              <div className="min-w-0">
                <PageHeading className="break-words">{plugin.display_name || plugin.name}</PageHeading>
                <p className="mt-1 font-mono text-sm text-gray-500 dark:text-gray-400">{plugin.name}</p>
              </div>
            </div>
          </div>
          <PluginToggle plugin={plugin} />
        </div>
      </header>

      <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <div className="space-y-6">
          <OverviewSection plugin={plugin} />
          <LinksSection plugin={plugin} />
          <ConfigSection plugin={plugin} />
          <ExtensionPointsSection plugin={plugin} />
          <RoutesSection plugin={plugin} />
          <DocsSection docs={plugin.docs} />
          <MetricsSection metrics={plugin.metrics} />
        </div>
        <MetadataRail plugin={plugin} />
      </div>
    </>
  )
}

function PluginToggle({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const navigate = useNavigate()
  const location = useLocation()
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: () => plugin.enabled ? disableAdminPlugin(plugin.name) : enableAdminPlugin(plugin.name),
    onSuccess: async (data) => {
      if ("requires_confirmation" in data && data.requires_confirmation) return
      await refreshSidebarPluginPages(queryClient)
      void queryClient.invalidateQueries({ queryKey: ["admin", "plugins", plugin.name] })
      if (!plugin.enabled) navigate(location.pathname)
    }
  })

  return (
    <div className="flex flex-col items-start gap-2 sm:items-end">
      <Button
        disabled={mutation.isPending || (plugin.enabled && !plugin.disableable)}
        onClick={() => mutation.mutate()}
        variant={plugin.enabled ? "secondary" : "primary"}
      >
        {mutation.isPending ? t("plugins.saving") : plugin.enabled ? t("plugins.disable") : t("plugins.enable")}
      </Button>
      {mutation.isError ? <p className="text-sm text-red-700 dark:text-red-300">{errorMessage(mutation.error, t("plugins.error_toggle"))}</p> : null}
    </div>
  )
}

function OverviewSection({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const health = plugin.health || { state: "ok", reasons: [] }

  return (
    <Surface aria-label={t("plugins.overview_heading")} className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <SectionHeading>{t("plugins.overview_heading")}</SectionHeading>
        <StatusBadge status={plugin.enabled ? "enabled" : "disabled"} label={plugin.enabled ? t("plugins.enabled") : t("plugins.disabled")} />
        <StatusBadge status={health.state} label={health.state === "ok" ? t("plugins.health_ok") : health.state} />
        {!plugin.disableable ? <StatusBadge status="required" label={t("plugins.required")} /> : null}
      </div>
      {plugin.description ? <p className="text-sm leading-6 text-gray-700 dark:text-gray-300">{plugin.description}</p> : null}
      {plugin.long_description ? <p className="whitespace-pre-line text-sm leading-6 text-gray-700 dark:text-gray-300">{plugin.long_description}</p> : null}
      {health.reasons.length > 0 ? <p className="text-sm text-amber-700 dark:text-amber-300">{health.reasons.join("; ")}</p> : null}
      {plugin.recommendation ? (
        <p className="rounded border border-info/30 bg-info/10 px-3 py-2 text-sm leading-6 text-info">
          <span className="font-medium">{t("plugins.suggested")}</span> {plugin.recommendation.reason} <span className="font-mono text-xs">({plugin.recommendation.evidence})</span>
        </p>
      ) : null}
    </Surface>
  )
}

function LinksSection({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const links = (plugin.links || []).filter((link) => plugin.enabled || link.requires_enabled === false)

  return (
    <Surface aria-label={t("plugins.links_heading")} className="space-y-3">
      <SectionHeading>{t("plugins.links_heading")}</SectionHeading>
      {links.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {links.map((link) => <PluginLinkAction key={`${link.label}-${link.path}`} link={link} prefix={prefix} />)}
        </div>
      ) : (
        <p className="text-sm text-gray-500 dark:text-gray-400">{plugin.enabled ? t("plugins.no_links") : t("plugins.links_disabled")}</p>
      )}
    </Surface>
  )
}

function PluginLinkAction({ link, prefix }: { link: AdminPluginLink; prefix: string }) {
  const external = /^https?:\/\//.test(link.path)
  if (external) {
    return <a className={buttonClasses("primary")} href={link.path} rel="noreferrer" target="_blank" title={link.description || undefined}>{link.label}</a>
  }
  return <Link className={buttonClasses("primary")} title={link.description || undefined} to={withRoutePrefix(link.path, prefix)}>{link.label}</Link>
}

function ConfigSection({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const schema = plugin.config_schema || []
  const config = plugin.config || {}

  return (
    <Surface aria-label={t("plugins.config_heading")} className="space-y-3">
      <SectionHeading>{t("plugins.config_heading")}</SectionHeading>
      {schema.length > 0 ? (
        <dl className="grid gap-3 sm:grid-cols-2">
          {schema.map((entry) => (
            <div className="rounded border border-gray-200 p-3 dark:border-gray-800" key={entry.key}>
              <dt className="text-sm font-medium text-gray-900 dark:text-gray-100">{entry.label || entry.key}</dt>
              <dd className="mt-1 font-mono text-xs text-gray-600 dark:text-gray-300">{formatConfigValue(config[entry.key])}</dd>
              {entry.description ? <p className="mt-2 text-xs leading-5 text-gray-500 dark:text-gray-400">{entry.description}</p> : null}
            </div>
          ))}
        </dl>
      ) : (
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_config")}</p>
      )}
    </Surface>
  )
}

function ExtensionPointsSection({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")

  return (
    <Surface aria-label={t("plugins.extension_points_heading")} className="space-y-3">
      <SectionHeading>{t("plugins.extension_points_heading")}</SectionHeading>
      {plugin.extension_points.length > 0 ? (
        <div className="overflow-x-auto">
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
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_extension_points")}</p>
      )}
    </Surface>
  )
}

function RoutesSection({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const routes = plugin.routes || []

  return (
    <Surface aria-label={t("plugins.routes_heading")} className="space-y-3">
      <SectionHeading>{t("plugins.routes_heading")}</SectionHeading>
      {routes.length > 0 ? (
        <ul className="space-y-2">
          {routes.map((route, index) => (
            <li className="rounded border border-gray-200 p-3 font-mono text-xs dark:border-gray-800" key={`${route.verb}-${route.path}-${index}`}>
              <span>{route.verb}</span> <span>{route.path}</span>
              {route.controller ? <span className="text-gray-500 dark:text-gray-400">{" -> "}{route.controller}</span> : null}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_routes")}</p>
      )}
    </Surface>
  )
}

function DocsSection({ docs }: { docs: Array<{ title: string; path: string; body: string }> }) {
  const { t } = useT("admin")

  return (
    <Surface aria-label={t("plugins.docs_heading")} className="space-y-4">
      <SectionHeading>{t("plugins.docs_heading")}</SectionHeading>
      {docs.length > 0 ? docs.map((doc) => (
        <article className="space-y-2" key={doc.path}>
          <div>
            <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{doc.title}</h3>
            <p className="font-mono text-xs text-gray-500 dark:text-gray-400">{doc.path}</p>
          </div>
          <Markdown className="text-sm text-gray-700 dark:text-gray-300" text={doc.body} />
        </article>
      )) : <p className="text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_docs")}</p>}
    </Surface>
  )
}

function MetricsSection({ metrics }: { metrics: AdminPluginMetric[] }) {
  const { t } = useT("admin")

  return (
    <Surface aria-label={t("plugins.metrics_heading")} className="space-y-3">
      <SectionHeading>{t("plugins.metrics_heading")}</SectionHeading>
      {metrics.length > 0 ? (
        <div className="overflow-x-auto">
          <table className="min-w-full text-left text-sm">
            <thead className="border-b border-gray-200 text-xs uppercase text-gray-500 dark:border-gray-800 dark:text-gray-400">
              <tr>
                <th className="py-2 pr-4 font-medium">{t("plugins.col_metric")}</th>
                <th className="py-2 pr-4 font-medium">{t("plugins.col_type")}</th>
                <th className="py-2 pr-4 font-medium">{t("plugins.col_tags")}</th>
                <th className="py-2 font-medium">{t("plugins.col_current")}</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {metrics.map((metric) => (
                <tr key={metric.name}>
                  <td className="py-3 pr-4">
                    <p className="font-mono text-xs text-gray-900 dark:text-gray-100">{metric.name}</p>
                    {metric.comment ? <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{metric.comment}</p> : null}
                  </td>
                  <td className="py-3 pr-4 font-mono text-xs">{metric.type}</td>
                  <td className="py-3 pr-4 font-mono text-xs">{metric.tags.length > 0 ? metric.tags.join(", ") : t("plugins.none")}</td>
                  <td className="py-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <StatusBadge status={metric.available ? "available" : "disabled"} label={metric.available ? t("plugins.metric_available") : t("plugins.metric_unavailable")} />
                      {metric.latest_sample ? <span className="font-mono text-xs">{metric.latest_sample.value}</span> : null}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="text-sm text-gray-500 dark:text-gray-400">{t("plugins.no_metrics")}</p>
      )}
    </Surface>
  )
}

function MetadataRail({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const rows = [
    [t("plugins.version"), plugin.version],
    [t("plugins.category"), plugin.category_label || plugin.category || t("plugins.none")],
    [t("plugins.default_state"), plugin.default_enabled ? t("plugins.enabled") : t("plugins.disabled")],
    [t("plugins.disableability"), plugin.disableable ? t("plugins.disableable") : t("plugins.required")],
    plugin.author ? [t("plugins.author"), plugin.author] : null,
    plugin.homepage ? [t("plugins.homepage"), plugin.homepage] : null,
    plugin.source ? [t("plugins.source"), plugin.source] : null,
    [t("plugins.depends_on"), listValue(plugin.depends_on, t)],
    [t("plugins.optionally_depends_on"), listValue(plugin.optionally_depends_on, t)],
    [t("plugins.conflicts_with"), listValue(plugin.conflicts_with, t)],
    [t("plugins.required_by"), listValue(plugin.dependents, t)]
  ].filter(Boolean) as string[][]

  return (
    <aside className="space-y-3">
      <Surface className="space-y-3">
        <SectionHeading>{t("plugins.metadata_heading")}</SectionHeading>
        <dl className="space-y-3">
          {rows.map(([label, value]) => (
            <div key={label}>
              <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</dt>
              <dd className="mt-1 break-words text-sm text-gray-800 dark:text-gray-200">{value}</dd>
            </div>
          ))}
        </dl>
      </Surface>
    </aside>
  )
}

function listValue(values: string[] | undefined, t: (key: string, opts?: Record<string, unknown>) => string) {
  return values && values.length > 0 ? values.join(", ") : t("plugins.none")
}

function formatConfigValue(value: unknown) {
  if (value && typeof value === "object" && "present" in value) return (value as { present?: boolean }).present ? "present" : "missing"
  if (value === null || value === undefined || value === "") return "unset"
  if (typeof value === "string") return value
  return JSON.stringify(value)
}

function PanelMessage({ children, tone = "muted" }: { children: string; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
