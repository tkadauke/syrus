import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation } from "react-router-dom"
import {
  fetchAdminInstallations,
  refreshInstallations,
  type AdminInstallationsPayload,
  type InstallationRepository,
  type PatOwnerGroup
} from "../api/adminInstallations"
import { ApiError } from "../api/client"
import { Button } from "../components/Button"
import { PageHeading, SectionHeading } from "../components/Heading"
import { useT } from "../hooks/useT"
import { DataTable, Page } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  visibleColumns,
  type DataTableColumnDef
} from "../components/dataTable"

export function AdminInstallations() {
  const { t } = useT("admin")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const installations = useQuery({
    queryKey: ["admin", "installations"],
    queryFn: fetchAdminInstallations
  })

  return (
    <Page.Root aria-label={t("aria_installations")} gutter="responsive">
      <Page.Header className="block border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <PageHeading className="mt-1">{t("installations.heading")}</PageHeading>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">
          {t("installations.description")}
        </p>
      </Page.Header>

      {installations.isPending ? <PanelMessage>{t("installations.loading")}</PanelMessage> : null}
      {installations.isError ? <InstallationsError error={installations.error} /> : null}
      {installations.isSuccess ? <InstallationsView payload={installations.data} prefix={prefix} /> : null}
    </Page.Root>
  )
}

function InstallationsView({ payload, prefix }: { payload: AdminInstallationsPayload; prefix: string }) {
  const { t } = useT("admin")

  return (
    <>
      {!payload.github_app_registered ? (
        <section className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 px-4 py-3 text-sm text-amber-900 dark:text-amber-100">
          <div className="font-semibold">{t("installations.app_not_registered_title")}</div>
          <p className="mt-1">{t("installations.app_not_registered_body")}</p>
          <Link className="mt-3 inline-block rounded bg-amber-600 dark:bg-amber-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500 dark:hover:bg-amber-400" to={withRoutePrefix("/admin/github_app/register", prefix)}>{t("installations.run_manifest_flow")}</Link>
        </section>
      ) : null}

      <section className="space-y-3">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <SectionHeading>{t("installations.credential_modes")}</SectionHeading>
          <RefreshButton />
        </div>
        <SyncStatus payload={payload} />
        <CredentialModeComparison />
      </section>

      {payload.github_app_registered && payload.pat_owner_groups.length > 0 ? (
        <PatOwnerGroups groups={payload.pat_owner_groups} />
      ) : null}

      <RepositoriesTable repositories={payload.repositories} />
    </>
  )
}

function SyncStatus({ payload }: { payload: AdminInstallationsPayload }) {
  const { t } = useT("admin")
  const sync = payload.latest_sync
  const attempted = sync.last_attempted_at ? new Date(sync.last_attempted_at).toLocaleString() : t("installations.sync_never")
  const successful = sync.last_successful_at ? new Date(sync.last_successful_at).toLocaleString() : t("installations.sync_never")
  const details = [
    t("installations.sync_attempted", { value: attempted }),
    t("installations.sync_successful", { value: successful }),
    sync.records_seen == null ? null : t("installations.sync_records", { count: sync.records_seen }),
    sync.duration_ms == null ? null : t("installations.sync_duration", { value: sync.duration_ms })
  ].filter(Boolean).join(" · ")

  return (
    <div className={`rounded border px-4 py-3 text-sm ${sync.error_class ? "border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100" : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"}`}>
      <div className="font-medium text-gray-900 dark:text-gray-100">{t("installations.sync_status")}</div>
      <div className="mt-1">{details}</div>
      {sync.error_class ? <div className="mt-1 font-mono text-xs">{sync.error_class}: {sync.error_message}</div> : null}
    </div>
  )
}

function RefreshButton() {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const refresh = useMutation({
    mutationFn: refreshInstallations,
    onSuccess: (payload) => {
      queryClient.setQueryData(["admin", "installations"], payload)
    }
  })

  return (
    <Button
      disabled={refresh.isPending}
      onClick={() => refresh.mutate()}
    >
      {refresh.isPending ? t("installations.refreshing") : t("installations.refresh")}
    </Button>
  )
}

// Left off the shared column-config primitive: this is fixed explanatory
// reference content (five hardcoded PAT-vs-App comparison sentences), not a
// list of records -- there's nothing here for an operator to show/hide or
// reorder.
function CredentialModeComparison() {
  const { t } = useT("admin")
  const rows = [
    [t("installations.compare_pat_1"), t("installations.compare_app_1")],
    [t("installations.compare_pat_2"), t("installations.compare_app_2")],
    [t("installations.compare_pat_3"), t("installations.compare_app_3")],
    [t("installations.compare_pat_4"), t("installations.compare_app_4")],
    [t("installations.compare_pat_5"), t("installations.compare_app_5")]
  ]

  return (
    <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("installations.col_pat")}</th>
            <th className="px-4 py-2">{t("installations.col_app")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map(([pat, app]) => (
            <tr key={pat}>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{pat}</td>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{app}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function PatOwnerGroups({ groups }: { groups: PatOwnerGroup[] }) {
  const { t } = useT("admin")

  return (
    <section className="space-y-3">
      <SectionHeading>{t("installations.install_on_pat_repos")}</SectionHeading>
      <div className="divide-y divide-gray-100 dark:divide-gray-800 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {groups.map((group) => (
          <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={group.owner}>
            <div>
              <div className="font-mono text-sm text-gray-900 dark:text-gray-100">{group.owner}</div>
              <div className="text-xs text-gray-500 dark:text-gray-400">{t("installations.pat_repos_count", { count: group.repository_count })}</div>
            </div>
            {group.install_url ? (
              <a className="rounded bg-amber-600 dark:bg-amber-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500 dark:hover:bg-amber-400" href={group.install_url} rel="noopener" target="_blank">
                {t("installations.install_on_all")}
              </a>
            ) : (
              <span className="text-xs text-gray-500 dark:text-gray-400">{t("installations.github_ids_missing")}</span>
            )}
          </div>
        ))}
      </div>
    </section>
  )
}

const INSTALLATIONS_REPOSITORIES_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.admin.installations.repositories.visible_columns"

function buildInstallationsRepositoriesColumns(t: (key: string) => string): DataTableColumnDef<InstallationRepository>[] {
  return [
    { key: "repository", label: t("installations.col_repository"), required: true, cellClassName: "font-mono", renderCell: (repository) => repository.slug },
    { key: "syrus_owner", label: t("installations.col_syrus_owner"), cellClassName: "text-gray-600 dark:text-gray-300", renderCell: (repository) => repository.owner_user.email_address },
    {
      key: "app_credential",
      label: t("installations.col_app_credential"),
      renderCell: (repository) => repository.app_credential_active ? (
        <span className="font-medium text-emerald-700 dark:text-emerald-300">{t("installations.app_active")}</span>
      ) : (
        <div>
          <span className="text-gray-700 dark:text-gray-200">{t("installations.no_active_installation")}</span>
          {repository.app_credential_inactive_reason ? <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{fallbackReasonLabel(repository.app_credential_inactive_reason, t)}</div> : null}
        </div>
      )
    },
    {
      key: "pat_credential",
      label: t("installations.col_pat_credential"),
      renderCell: (repository) => repository.app_credential_active ? <span className="text-gray-400">{t("installations.not_used")}</span> : <span className="font-medium text-amber-800 dark:text-amber-200">{t("installations.used_as_fallback")}</span>
    },
    {
      key: "account",
      label: t("installations.col_account"),
      cellClassName: "text-gray-600 dark:text-gray-300",
      renderCell: (repository) => (
        <>
          {repository.account_login}
          {repository.installation_removed_at ? <span className="ml-1 text-xs text-amber-700 dark:text-amber-300">{t("installations.removed")}</span> : null}
        </>
      )
    }
  ]
}

function RepositoriesTable({ repositories }: { repositories: InstallationRepository[] }) {
  const { t } = useT("admin")
  const columns = buildInstallationsRepositoriesColumns(t)
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: INSTALLATIONS_REPOSITORIES_VISIBLE_COLUMNS_STORAGE_KEY })
  const colSpan = visibleColumns({ columns, order: preferences.order }).length

  return (
    <section>
      <div className="mb-3 flex items-center justify-between gap-3">
        <SectionHeading>{t("installations.repositories_heading")}</SectionHeading>
        <DataTableColumnMenu
          columns={columns}
          downLabel={t("event_log_table.column_down")}
          menuId="admin-installations-repositories-columns-menu"
          moveDownLabel={(title) => t("event_log_table.column_move_down", { title })}
          moveUpLabel={(title) => t("event_log_table.column_move_up", { title })}
          onChange={preferences.onChange}
          order={preferences.order}
          triggerAriaLabel={t("event_log_table.columns")}
          upLabel={t("event_log_table.column_up")}
          visibleLabel={t("event_log_table.visible_columns")}
        />
      </div>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <DataTable.Root>
          <DataTable.Header>
            <DataTableColumnHeaderRow columns={columns} onReorder={preferences.onChange} order={preferences.order} />
          </DataTable.Header>
          <DataTable.Body>
            {repositories.length === 0 ? (
              <DataTable.Empty colSpan={colSpan}>{t("installations.no_repositories")}</DataTable.Empty>
            ) : repositories.map((repository) => (
              <DataTable.Row key={repository.id}>
                <DataTableColumnCells columns={columns} order={preferences.order} row={repository} />
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      </div>
    </section>
  )
}

function InstallationsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("installations.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function fallbackReasonLabel(reason: string, t: (key: string) => string) {
  const keys = new Set([
    "github_app_not_registered",
    "github_app_private_key_missing",
    "github_repository_ids_missing",
    "repository_installation_link_missing",
    "linked_installation_removed",
    "removed_installation_for_owner",
    "owner_mismatch_or_not_installed",
    "no_installations_synced"
  ])
  return keys.has(reason) ? t(`installations.reasons.${reason}`) : reason
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
