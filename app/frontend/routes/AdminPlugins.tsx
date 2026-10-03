import { useMutation, useQuery } from "@tanstack/react-query"
import { SectionHeading } from "../components/Heading"
import { type ReactNode, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import {
  disableAdminPlugin,
  enableAdminPlugin,
  fetchAdminPlugin,
  fetchAdminPlugins,
  type AdminPlugin,
  type AdminPluginDisableConfirmation,
  type AdminPluginExtensionPoint,
  type AdminPluginsPayload
} from "../api/adminPlugins"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { Button, buttonClasses } from "../components/Button"
import { FilterBar, filterTreeFromPayload, topFilterChildren } from "../components/FilterBar"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Markdown } from "../lib/Markdown"
import * as pageReload from "../lib/pageReload"
import { DataTable, Page } from "../components/ui"

export function AdminPlugins() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_plugins"))
  const location = useLocation()

  const plugins = useQuery({
    queryKey: ["admin", "plugins", location.search],
    queryFn: () => fetchAdminPlugins(location.search),
    placeholderData: (previousData) => previousData
  })

  const isFiltered = plugins.isSuccess && topFilterChildren(filterTreeFromPayload(plugins.data.filter)).length > 0

  return (
    <Page.Root aria-label={t("plugins.aria_plugins")} gutter="responsive">
      <Page.Header className="block border-b border-gray-200 pb-4 dark:border-gray-700">
        <Page.HeadingGroup>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <Page.Title className="mt-1">{t("plugins.heading")}</Page.Title>
        </Page.HeadingGroup>
      </Page.Header>

      {plugins.isPending ? <PanelMessage>{t("plugins.loading")}</PanelMessage> : null}
      {plugins.isError ? <PanelMessage tone="error">{errorMessage(plugins.error, t("plugins.error_load"))}</PanelMessage> : null}
      {plugins.isSuccess ? (
        <AdminFiltersLayout
          filterBar={
            <FilterBar
              filter={plugins.data.filter}
              filterSchema={plugins.data.controls?.filter_schema || []}
              pathname={location.pathname}
              search={location.search}
            />
          }
        >
          <PluginsView isFiltered={isFiltered} plugins={plugins.data.plugins} />
        </AdminFiltersLayout>
      ) : null}
    </Page.Root>
  )
}

export function AdminPluginDetail() {
  const { t } = useT("admin")
  const { name = "" } = useParams()
  usePageTitle(t("page_title_plugin_detail"))

  const plugin = useQuery({
    queryKey: ["admin", "plugins", name],
    queryFn: () => fetchAdminPlugin(name),
    enabled: name.length > 0
  })

  return (
    <Page.Root aria-label={t("plugins.detail_aria")} gutter="responsive">
      <Page.Header>
        <Link className="text-sm font-medium text-brand hover:underline" to="/admin/plugins">
          {t("plugins.back_to_plugins")}
        </Link>
      </Page.Header>
      {plugin.isPending ? <PanelMessage>{t("plugins.detail_loading")}</PanelMessage> : null}
      {plugin.isError ? <PanelMessage tone="error">{errorMessage(plugin.error, t("plugins.detail_error_load"))}</PanelMessage> : null}
      {plugin.isSuccess ? <PluginDetailView plugin={plugin.data.plugin} /> : null}
    </Page.Root>
  )
}

function PluginsView({ plugins, isFiltered }: { plugins: AdminPlugin[]; isFiltered: boolean }) {
  const { t } = useT("admin")
  if (plugins.length === 0) {
    return (
      <section className="rounded border border-dashed border-gray-300 bg-white p-8 text-center dark:border-gray-700 dark:bg-gray-900">
        <SectionHeading>{isFiltered ? t("plugins.no_results_heading") : t("plugins.no_plugins_heading")}</SectionHeading>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{isFiltered ? t("plugins.no_results_body") : t("plugins.no_plugins_body")}</p>
      </section>
    )
  }

  return (
    <section aria-label={t("plugins.list_aria")} className="space-y-4">
      {plugins.map((plugin) => (
        <PluginCard key={plugin.name} plugin={plugin} />
      ))}
    </section>
  )
}

function PluginCard({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const navigate = useNavigate()
  const dependsOn = plugin.depends_on || []
  const dependents = plugin.dependents || []
  const toggleState = usePluginToggle(plugin, (nowEnabled) => {
    if (nowEnabled) {
      navigate(`/admin/plugins/${encodeURIComponent(plugin.name)}`)
    } else {
      pageReload.reloadPage()
    }
  })
  const { disableBlocked, disableBlockers } = toggleState

  return (
    <article className="rounded border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            {plugin.icon_url ? <img alt="" aria-hidden="true" className="h-5 w-5 shrink-0" src={plugin.icon_url} /> : null}
            <SectionHeading className="break-words">
              <Link className="hover:underline" to={`/admin/plugins/${encodeURIComponent(plugin.name)}`}>
                {plugin.display_name || plugin.name}
              </Link>
            </SectionHeading>
            {plugin.display_name && plugin.display_name !== plugin.name ? (
              <span className="font-mono text-xs text-gray-500 dark:text-gray-400">{plugin.name}</span>
            ) : null}
            <span className="rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">{plugin.version}</span>
            <StatusBadge status={plugin.enabled ? "enabled" : "disabled"} label={plugin.enabled ? t("plugins.enabled") : t("plugins.disabled")} />
            {!plugin.disableable ? <StatusBadge status="required" label={t("plugins.required")} /> : null}
          </div>
          {plugin.description ? <p className="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">{plugin.description}</p> : null}
          {plugin.long_description ? (
            <p className="mt-2 whitespace-pre-line text-sm leading-6 text-gray-600 dark:text-gray-300">{plugin.long_description}</p>
          ) : null}
          <div className="mt-3 flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            {plugin.category ? (
              <span>
                {t("plugins.category")}: <span className="font-mono">{plugin.category_label || plugin.category}</span>
              </span>
            ) : null}
            <span>
              {t("plugins.default_state")}: {plugin.default_enabled ? t("plugins.enabled") : t("plugins.disabled")}
            </span>
            {dependsOn.length > 0 ? (
              <span>
                {t("plugins.depends_on")}: <span className="font-mono">{dependsOn.join(", ")}</span>
              </span>
            ) : null}
            {dependents.length > 0 ? (
              <span>
                {t("plugins.required_by")}: <span className="font-mono">{dependents.join(", ")}</span>
              </span>
            ) : null}
          </div>
          {plugin.recommendation ? (
            <p className="mt-3 rounded border border-info/25 bg-info/10 px-3 py-2 text-sm leading-6 text-info">
              <span className="font-medium">{t("plugins.suggested")}</span> {plugin.recommendation.reason}{" "}
              <span className="font-mono text-xs">({plugin.recommendation.evidence})</span>
            </p>
          ) : null}
        </div>
        <div className="flex shrink-0 flex-col items-start gap-3 sm:items-end">
          <PluginToggleButton plugin={plugin} state={toggleState} />
        </div>
      </div>

      <PluginCascadeConfirmation state={toggleState} />

      {disableBlocked ? (
        <details className="mt-4">
          <summary className="cursor-pointer select-none text-xs font-medium uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
            {t("plugins.usage_heading")}
          </summary>
          <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-amber-700 dark:text-amber-300">
            {disableBlockers.map((blocker) => (
              <li key={`${blocker.kind}-${blocker.label}`}>
                {blocker.label}: {blocker.count}
              </li>
            ))}
          </ul>
        </details>
      ) : null}
    </article>
  )
}

function usePluginToggle(plugin: AdminPlugin, onToggled: (nowEnabled: boolean) => void) {
  const { t } = useT("admin")
  const [pendingCascade, setPendingCascade] = useState<AdminPluginDisableConfirmation | null>(null)
  const toggle = useMutation<AdminPluginsPayload | AdminPluginDisableConfirmation, unknown, boolean | undefined>({
    mutationFn: (confirmCascade) => (plugin.enabled ? disableAdminPlugin(plugin.name, confirmCascade) : enableAdminPlugin(plugin.name)),
    onSuccess: (data) => {
      if ("requires_confirmation" in data && data.requires_confirmation) {
        setPendingCascade(data)
        return
      }
      onToggled(!plugin.enabled)
    }
  })
  const disableBlockers = plugin.disable_blockers || []
  const disableBlocked = plugin.enabled && disableBlockers.length > 0

  let disableTooltip: string | undefined
  if (plugin.enabled && !plugin.disableable) {
    disableTooltip = t("plugins.required")
  } else if (disableBlocked) {
    disableTooltip = disableBlockers.length === 1 ? `${disableBlockers[0].label}: ${disableBlockers[0].count}` : t("plugins.disable_blocked_tooltip_many")
  }

  return { toggle, pendingCascade, setPendingCascade, disableTooltip, disableBlocked, disableBlockers }
}

type PluginToggleState = ReturnType<typeof usePluginToggle>

function PluginToggleButton({ plugin, state }: { plugin: AdminPlugin; state: PluginToggleState }) {
  const { t } = useT("admin")
  const { toggle, disableTooltip, disableBlocked } = state

  return (
    <div>
      <span title={disableTooltip}>
        <Button
          disabled={toggle.isPending || (plugin.enabled && (!plugin.disableable || disableBlocked))}
          onClick={() => toggle.mutate(undefined)}
          variant="secondary"
        >
          {toggle.isPending ? t("plugins.saving") : plugin.enabled ? t("plugins.disable") : t("plugins.enable")}
        </Button>
      </span>
      {toggle.isError ? <p className="mt-2 text-sm text-red-700 dark:text-red-300">{errorMessage(toggle.error, t("plugins.error_toggle"))}</p> : null}
    </div>
  )
}

function PluginCascadeConfirmation({ state }: { state: PluginToggleState }) {
  const { t } = useT("admin")
  const { pendingCascade, setPendingCascade, toggle } = state
  if (!pendingCascade) return null

  return (
    <div className="mt-4 rounded border border-amber-300 bg-amber-50 p-3 text-sm dark:border-amber-700 dark:bg-amber-950">
      <p className="font-medium text-amber-900 dark:text-amber-200">{t("plugins.cascade_confirm_heading")}</p>
      <p className="mt-1 text-amber-800 dark:text-amber-300">{t("plugins.cascade_confirm_body")}</p>
      <ul className="mt-2 list-disc space-y-1 pl-5 text-amber-800 dark:text-amber-300">
        {pendingCascade.dependents.map((name) => (
          <li key={name}>{name}</li>
        ))}
      </ul>
      <div className="mt-3 flex gap-2">
        <Button disabled={toggle.isPending} onClick={() => toggle.mutate(true)} variant="danger">
          {toggle.isPending ? t("plugins.saving") : t("plugins.cascade_confirm_cta")}
        </Button>
        <Button disabled={toggle.isPending} onClick={() => setPendingCascade(null)} variant="secondary">
          {t("plugins.cascade_cancel")}
        </Button>
      </div>
    </div>
  )
}

function PluginMetadata({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const rows: [string, ReactNode][] = []
  if (plugin.author) rows.push([t("plugins.author"), plugin.author])
  if (plugin.homepage) rows.push([t("plugins.homepage"), <HomepageLink homepage={plugin.homepage} key="homepage" />])

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

function HomepageLink({ homepage }: { homepage: string }) {
  return (
    <a className="text-info underline hover:no-underline" href={homepage} rel="noreferrer" target="_blank">
      {homepage}
    </a>
  )
}

function PluginDetailView({ plugin }: { plugin: AdminPlugin }) {
  const { t } = useT("admin")
  const visibleLinks = (plugin.links || []).filter((link) => plugin.enabled || link.enabled_only === false)
  const disableBlockers = plugin.disable_blockers || []
  const disableBlocked = plugin.enabled && disableBlockers.length > 0
  const toggleState = usePluginToggle(plugin, () => pageReload.reloadPage())

  return (
    <>
      <Page.Header className="block border-b border-gray-200 pb-5 dark:border-gray-700">
        <div className="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-3">
              {plugin.icon_url ? <img alt="" aria-hidden="true" className="h-9 w-9 shrink-0" src={plugin.icon_url} /> : null}
              <Page.Title className="break-words">{plugin.display_name || plugin.name}</Page.Title>
              <span className="font-mono text-sm text-gray-500 dark:text-gray-400">{plugin.name}</span>
              <StatusBadge status={plugin.enabled ? "enabled" : "disabled"} label={plugin.enabled ? t("plugins.enabled") : t("plugins.disabled")} />
              {plugin.health ? <StatusBadge status={plugin.health.state} label={`${t("plugins.health")}: ${plugin.health.state}`} /> : null}
            </div>
            {plugin.health && plugin.health.reasons.length > 0 ? (
              <ul className="mt-3 list-disc space-y-1 pl-5 text-sm text-amber-700 dark:text-amber-300">
                {plugin.health.reasons.map((reason) => (
                  <li key={reason}>{reason}</li>
                ))}
              </ul>
            ) : null}
            {plugin.description ? <p className="mt-3 max-w-3xl text-sm leading-6 text-gray-700 dark:text-gray-200">{plugin.description}</p> : null}
            {plugin.long_description ? (
              <p className="mt-3 max-w-3xl whitespace-pre-line text-sm leading-6 text-gray-600 dark:text-gray-300">{plugin.long_description}</p>
            ) : null}
            {plugin.recommendation ? (
              <p className="mt-3 max-w-3xl rounded border border-info/25 bg-info/10 px-3 py-2 text-sm leading-6 text-info">
                <span className="font-medium">{t("plugins.suggested")}</span> {plugin.recommendation.reason}{" "}
                <span className="font-mono text-xs">({plugin.recommendation.evidence})</span>
              </p>
            ) : null}
          </div>
          <div className="flex shrink-0 flex-col items-start gap-3 md:items-end">
            <PluginToggleButton plugin={plugin} state={toggleState} />
            <PluginMetadata plugin={plugin} />
          </div>
        </div>
        <PluginCascadeConfirmation state={toggleState} />
        {disableBlocked ? (
          <details className="mt-4">
            <summary className="cursor-pointer select-none text-xs font-medium uppercase text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
              {t("plugins.usage_heading")}
            </summary>
            <ul className="mt-2 list-disc space-y-1 pl-5 text-sm text-amber-700 dark:text-amber-300">
              {disableBlockers.map((blocker) => (
                <li key={`${blocker.kind}-${blocker.label}`}>
                  {blocker.label}: {blocker.count}
                </li>
              ))}
            </ul>
          </details>
        ) : null}
        {visibleLinks.length > 0 ? (
          <div className="mt-4 flex flex-wrap gap-2">
            {visibleLinks.map((link) => (
              <a className={buttonClasses("primary")} href={link.href} key={`${link.kind}-${link.href}`}>
                {link.label}
              </a>
            ))}
          </div>
        ) : null}
      </Page.Header>

      <div className="grid min-w-0 gap-6 lg:grid-cols-[minmax(0,1fr)_18rem]">
        <div className="min-w-0 space-y-6">
          <DetailSection title={t("plugins.config_heading")}>
            {(plugin.config_schema || []).length > 0 ? (
              <div className="space-y-2">
                {(plugin.config_schema || []).map((entry) => {
                  const key = String(entry["key"])
                  return <KeyValueLine key={key} label={String(entry["label"] || key)} value={formatConfigValue(plugin.config?.[key])} />
                })}
              </div>
            ) : (
              <EmptyText>{t("plugins.no_config")}</EmptyText>
            )}
          </DetailSection>

          <DetailSection title={t("plugins.docs_heading")}>
            {(plugin.docs || []).length > 0 ? (
              <div className="space-y-4">
                {(plugin.docs || []).map((doc) => (
                  <article
                    className="min-w-0 overflow-hidden rounded border border-gray-200 p-4 dark:border-gray-800"
                    data-testid="plugin-doc-card"
                    key={doc.path}
                  >
                    <div className="mb-2 flex min-w-0 flex-wrap items-center justify-between gap-2">
                      <SectionHeading className="break-words">{doc.title}</SectionHeading>
                      <span className="max-w-full break-all font-mono text-xs text-gray-500 dark:text-gray-400">{doc.path}</span>
                    </div>
                    <Markdown className="plugin-docs-prose min-w-0 text-sm text-gray-700 dark:text-gray-200" headingLevelOffset={1} text={doc.body} />
                  </article>
                ))}
              </div>
            ) : (
              <EmptyText>{t("plugins.no_docs")}</EmptyText>
            )}
          </DetailSection>

          {/* Metrics table left off the shared column-config primitive: this is one
              specific plugin's own static metric declarations (a small, fixed-shape
              technical registry), not a cross-plugin record list an operator would
              filter/reorder -- same reasoning as ExtensionPointsTable below. */}
          <DetailSection title={t("plugins.metrics_heading")}>
            {(plugin.metrics || []).length > 0 ? (
              <DataTable.Root>
                <DataTable.Header>
                  <DataTable.Row>
                    <DataTable.HeadCell>{t("plugins.col_metric")}</DataTable.HeadCell>
                    <DataTable.HeadCell>{t("plugins.col_type")}</DataTable.HeadCell>
                    <DataTable.HeadCell>{t("plugins.col_tags")}</DataTable.HeadCell>
                    <DataTable.HeadCell>{t("plugins.col_availability")}</DataTable.HeadCell>
                  </DataTable.Row>
                </DataTable.Header>
                <DataTable.Body>
                  {(plugin.metrics || []).map((metric) => (
                    <DataTable.Row key={metric.name}>
                      <DataTable.Cell>
                        <div className="font-mono text-xs text-gray-800 dark:text-gray-100">{metric.name}</div>
                        {metric.comment ? <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{metric.comment}</div> : null}
                      </DataTable.Cell>
                      <DataTable.Cell className="font-mono text-xs text-gray-700 dark:text-gray-200">{metric.type}</DataTable.Cell>
                      <DataTable.Cell className="font-mono text-xs text-gray-700 dark:text-gray-200">
                        {metric.tags.length > 0 ? metric.tags.join(", ") : "-"}
                      </DataTable.Cell>
                      <DataTable.Cell>
                        <StatusBadge
                          status={metric.available ? "available" : "disabled"}
                          label={metric.available ? t("plugins.metric_available") : t("plugins.metric_unavailable")}
                        />
                      </DataTable.Cell>
                    </DataTable.Row>
                  ))}
                </DataTable.Body>
              </DataTable.Root>
            ) : (
              <EmptyText>{t("plugins.no_metrics")}</EmptyText>
            )}
          </DetailSection>

          <DetailSection title={t("plugins.extension_points_heading")}>
            {plugin.extension_points.length > 0 ? (
              <ExtensionPointsTable extensions={plugin.extension_points} />
            ) : (
              <EmptyText>{t("plugins.no_extension_points")}</EmptyText>
            )}
          </DetailSection>

          <DetailSection title={t("plugins.routes_heading")}>
            {(plugin.routes || []).length > 0 ? (
              <div className="space-y-2">
                {(plugin.routes || []).map((route, index) => (
                  <KeyValueLine key={index} label={`${route["verb"] || ""} ${route["path"] || ""}`} value={String(route["controller"] || "")} />
                ))}
              </div>
            ) : (
              <EmptyText>{t("plugins.no_routes")}</EmptyText>
            )}
          </DetailSection>
        </div>

        <aside className="space-y-4">
          <DetailSection title={t("plugins.metadata_heading")}>
            <div className="space-y-2">
              <KeyValueLine label={t("plugins.author")} value={plugin.author || "-"} />
              <KeyValueLine label={t("plugins.version")} value={plugin.version || "-"} />
              <KeyValueLine label={t("plugins.category")} value={plugin.category_label || plugin.category || "-"} />
              <KeyValueLine label={t("plugins.default_state")} value={plugin.default_enabled ? t("plugins.enabled") : t("plugins.disabled")} />
              <KeyValueLine label={t("plugins.disableable")} value={plugin.disableable ? t("plugins.yes") : t("plugins.no")} />
              <KeyValueLine label={t("plugins.homepage")} value={plugin.homepage ? <HomepageLink homepage={plugin.homepage} /> : "-"} />
              <KeyValueLine label={t("plugins.source")} value={plugin.source || "-"} />
              <KeyValueLine label={t("plugins.depends_on")} value={(plugin.depends_on || []).join(", ") || "-"} />
              <KeyValueLine label={t("plugins.optional_depends_on")} value={(plugin.optionally_depends_on || []).join(", ") || "-"} />
              <KeyValueLine label={t("plugins.required_by")} value={(plugin.dependents || []).join(", ") || "-"} />
              <KeyValueLine label={t("plugins.conflicts_with")} value={(plugin.conflicts_with || []).join(", ") || "-"} />
            </div>
          </DetailSection>
        </aside>
      </div>
    </>
  )
}

function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="min-w-0 space-y-3">
      <SectionHeading>{title}</SectionHeading>
      {children}
    </section>
  )
}

function EmptyText({ children }: { children: ReactNode }) {
  return <p className="text-sm text-gray-500 dark:text-gray-400">{children}</p>
}

function KeyValueLine({ label, value }: { label: string; value: ReactNode }) {
  return (
    <dl className="grid gap-1 text-sm">
      <dt className="font-medium text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="break-words text-gray-800 dark:text-gray-100">{value}</dd>
    </dl>
  )
}

// Left off the shared column-config primitive: this is one plugin's own
// static extension-point registrations (extension point + implementing
// class + availability) -- a small, fixed-shape technical registry, not a
// record list with optional application columns to declutter.
function ExtensionPointsTable({ extensions }: { extensions: AdminPluginExtensionPoint[] }) {
  const { t } = useT("admin")
  return (
    <DataTable.Root>
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell>{t("plugins.col_extension_point")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("plugins.col_class")}</DataTable.HeadCell>
          <DataTable.HeadCell>{t("plugins.col_availability")}</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {extensions.map((extension) => (
          <ExtensionPointRow extension={extension} key={`${extension.extension_point}-${extension.class_name}`} />
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

function formatConfigValue(value: unknown) {
  if (value === null || typeof value === "undefined") return "-"
  if (typeof value === "object") return JSON.stringify(value)
  return String(value)
}

function ExtensionPointRow({ extension }: { extension: AdminPluginExtensionPoint }) {
  const { t } = useT("admin")
  const count = extension.availability.configured_count

  return (
    <DataTable.Row>
      <DataTable.Cell className="font-mono text-xs text-gray-700 dark:text-gray-200">{extensionPointLabel(extension.extension_point, t)}</DataTable.Cell>
      <DataTable.Cell className="font-mono text-xs text-gray-700 dark:text-gray-200">{extension.class_name}</DataTable.Cell>
      <DataTable.Cell>
        <div className="flex flex-wrap items-center gap-2">
          <StatusBadge label={extension.availability.label} status={extension.availability.status} />
          {typeof count === "number" ? <span className="text-xs text-gray-500 dark:text-gray-400">{t("plugins.configured_repos", { count })}</span> : null}
          {extension.availability.detail ? <span className="text-xs text-red-700 dark:text-red-300">{extension.availability.detail}</span> : null}
        </div>
      </DataTable.Cell>
    </DataTable.Row>
  )
}

function StatusBadge({ status, label }: { status: string; label: string }) {
  const tone = statusTone(status)
  return <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone}`}>{label}</span>
}

function statusTone(status: string) {
  if (["available", "configured", "enabled", "registered"].includes(status)) return "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
  if (status === "required") return "bg-info/10 text-info"
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
