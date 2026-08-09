import type { AdminPluginPage } from "../../api/adminPluginPages"

export type AdminNavGroup = {
  id: string
  labelKey: string
  order: number
}

export type CoreAdminNavItem = {
  id: string
  labelKey: string
  to: string
  paths: string[]
  groupId: string | null
  order: number
  visible?: (featureFlags: Record<string, boolean>) => boolean
}

export type MergedAdminNavItem = {
  id: string
  label: string
  to: string
  paths: string[]
  groupId: string | null
  order: number
}

export const ADMIN_NAV_GROUPS: readonly AdminNavGroup[] = [
  { id: "operations", labelKey: "nav_group_operations", order: 10 },
  { id: "observability", labelKey: "nav_group_observability", order: 20 },
  { id: "users_access", labelKey: "nav_group_users_access", order: 30 },
  { id: "system", labelKey: "nav_group_system", order: 40 },
  { id: "product_data", labelKey: "nav_group_product_data", order: 50 },
]

export const CORE_ADMIN_NAV_ITEMS: readonly CoreAdminNavItem[] = [
  { id: "overview", labelKey: "nav_overview", to: "/admin", paths: ["/admin"], groupId: null, order: 0 },
  { id: "queue", labelKey: "nav_queue", to: "/admin/queue", paths: ["/admin/queue"], groupId: "operations", order: 10 },
  { id: "stuck", labelKey: "nav_stuck", to: "/admin/stuck", paths: ["/admin/stuck"], groupId: "operations", order: 20 },
  { id: "reconciler_activity", labelKey: "nav_reconciler_activity", to: "/admin/reconciler_activity", paths: ["/admin/reconciler_activity"], groupId: "operations", order: 30 },
  { id: "processes", labelKey: "nav_processes", to: "/admin/processes", paths: ["/admin/processes"], groupId: "operations", order: 40 },
  { id: "console", labelKey: "nav_console", to: "/admin/console", paths: ["/admin/console"], groupId: "observability", order: 10 },
  { id: "resource_admission", labelKey: "nav_resource_admission", to: "/admin/resource_admission", paths: ["/admin/resource_admission"], groupId: "observability", order: 20 },
  { id: "users", labelKey: "nav_users", to: "/admin/users", paths: ["/admin/users"], groupId: "users_access", order: 10 },
  { id: "invitations", labelKey: "nav_invitations", to: "/invitations", paths: ["/invitations"], groupId: "users_access", order: 20 },
  { id: "github_app", labelKey: "nav_github_app", to: "/admin/github_app/register", paths: ["/admin/github_app"], groupId: "users_access", order: 30 },
  { id: "installations", labelKey: "nav_installations", to: "/admin/installations", paths: ["/admin/installations"], groupId: "users_access", order: 40 },
  { id: "settings", labelKey: "nav_settings", to: "/settings/edit", paths: ["/settings/edit"], groupId: "system", order: 10 },
  { id: "features", labelKey: "nav_features", to: "/admin/features", paths: ["/admin/features"], groupId: "system", order: 20, visible: (ff) => Object.keys(ff).length > 0 },
  { id: "plugins", labelKey: "nav_plugins", to: "/admin/plugins", paths: ["/admin/plugins"], groupId: "system", order: 30 },
  { id: "scoped_chat_events", labelKey: "nav_scoped_chat_events", to: "/admin/scoped_chat_events", paths: ["/admin/scoped_chat_events"], groupId: "product_data", order: 10 },
  { id: "insights", labelKey: "nav_insights", to: "/admin/insights", paths: ["/admin/insights"], groupId: "product_data", order: 20 },
]

const KNOWN_GROUP_IDS = new Set(ADMIN_NAV_GROUPS.map((g) => g.id))

export function buildAdminNavItems(
  featureFlags: Record<string, boolean>,
  pluginPages: AdminPluginPage[],
  translate: (key: string, options?: { defaultValue?: string }) => string
): {
  overviewItem: MergedAdminNavItem | undefined
  groups: Array<{ group: AdminNavGroup; items: MergedAdminNavItem[] }>
  ungroupedExtensions: MergedAdminNavItem[]
} {
  const coreItems: MergedAdminNavItem[] = CORE_ADMIN_NAV_ITEMS
    .filter((item) => !item.visible || item.visible(featureFlags))
    .map((item) => ({
      id: item.id,
      label: translate(item.labelKey),
      to: item.to,
      paths: item.paths,
      groupId: item.groupId,
      order: item.order,
    }))

  const pluginItems: MergedAdminNavItem[] = pluginPages.map((page) => ({
    id: page.id,
    label: page.label_key ? translate(page.label_key, { defaultValue: page.label }) : page.label,
    to: page.path,
    paths: page.paths,
    groupId: (page.group_id != null && KNOWN_GROUP_IDS.has(page.group_id)) ? page.group_id : null,
    order: page.order,
  }))

  const allItems = [...coreItems, ...pluginItems]
  const overviewItem = allItems.find((item) => item.id === "overview")
  const nonOverview = allItems.filter((item) => item.id !== "overview")

  const groups = ADMIN_NAV_GROUPS
    .map((group) => ({
      group,
      items: nonOverview
        .filter((item) => item.groupId === group.id)
        .sort((a, b) => a.order - b.order || a.label.localeCompare(b.label)),
    }))
    .filter(({ items }) => items.length > 0)

  const claimedIds = new Set(groups.flatMap(({ items }) => items.map((i) => i.id)))
  const ungroupedExtensions = nonOverview
    .filter((item) => !claimedIds.has(item.id))
    .sort((a, b) => a.order - b.order || a.label.localeCompare(b.label))

  return { overviewItem, groups, ungroupedExtensions }
}
