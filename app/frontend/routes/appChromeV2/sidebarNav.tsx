import type { ReactNode } from "react"
import type { SidebarPluginPage } from "../../api/sidebarPages"
import { DashboardIcon, PluginIcon, RepositoryIcon, ScheduleIcon, TeamIcon, TerminalIcon } from "./icons"

export type SidebarNavContext = {
  simpleMode: boolean
  featureFlags: Record<string, boolean>
  teamUserCount: number
}

export type CoreNavItem = {
  id: string
  labelKey: string
  to: (context: SidebarNavContext) => string
  icon: ReactNode
  order: number
  visible?: (context: SidebarNavContext) => boolean
}

export type MergedNavItem = {
  id: string
  label: string
  to: string
  icon: ReactNode
  order: number
}

// The primary sidebar nav, minus "spending" (kept as a separate hardcoded
// entry in AppChromeV2 for now — becoming the first sidebar_page plugin is
// tracked as a follow-up) and "setup" (onboarding-only, assembled separately).
export const CORE_NAV_ITEMS: readonly CoreNavItem[] = [
  { id: "dashboard", labelKey: "nav:dashboard", to: (ctx) => (ctx.simpleMode ? "/dashboard/epics" : "/dashboard/jobs"), icon: <DashboardIcon />, order: 10 },
  { id: "repositories", labelKey: "nav:repositories", to: () => "/repositories", icon: <RepositoryIcon />, order: 20 },
  { id: "schedules", labelKey: "nav:schedules", to: () => "/scheduled_tasks", icon: <ScheduleIcon />, order: 30, visible: (ctx) => !ctx.simpleMode },
  { id: "terminal", labelKey: "nav:terminal", to: () => "/terminal", icon: <TerminalIcon />, order: 40, visible: (ctx) => Boolean(ctx.featureFlags.terminal) },
  { id: "team", labelKey: "nav:team", to: () => "/profiles", icon: <TeamIcon />, order: 50, visible: (ctx) => ctx.teamUserCount > 1 },
]

// Known icon references a sidebar_page plugin may declare. Anything else
// (or a blank reference) falls back to a generic plugin glyph.
const PLUGIN_ICONS: Record<string, ReactNode> = {
  dashboard: <DashboardIcon />,
  repository: <RepositoryIcon />,
  schedule: <ScheduleIcon />,
  terminal: <TerminalIcon />,
  team: <TeamIcon />,
}

function resolvePluginIcon(icon: string | null | undefined): ReactNode {
  if (icon && PLUGIN_ICONS[icon]) return PLUGIN_ICONS[icon]
  return <PluginIcon />
}

// Appends enabled plugin-provided sidebar pages to the core nav, in
// provider-registration order (or by the declared `order` hint — see
// App::SidebarPagesPayload) if more than one plugin ever registers one.
export function buildSidebarNavItems(
  context: SidebarNavContext,
  pluginPages: SidebarPluginPage[],
  translate: (key: string, options?: { defaultValue?: string }) => string
): MergedNavItem[] {
  const coreItems: MergedNavItem[] = CORE_NAV_ITEMS
    .filter((item) => !item.visible || item.visible(context))
    .map((item) => ({
      id: item.id,
      label: translate(item.labelKey),
      to: item.to(context),
      icon: item.icon,
      order: item.order,
    }))

  const pluginItems: MergedNavItem[] = pluginPages.map((page) => ({
    id: page.id,
    label: page.label_key ? translate(page.label_key, { defaultValue: page.label }) : page.label,
    to: page.path,
    icon: resolvePluginIcon(page.icon),
    order: page.order,
  }))

  return [...coreItems, ...pluginItems]
}

export function sidebarNavItemActive(item: { id: string; to: string }, normalizedPath: string): boolean {
  if (item.id === "dashboard") return normalizedPath === "/" || normalizedPath.startsWith("/dashboard")
  return normalizedPath.startsWith(item.to)
}
