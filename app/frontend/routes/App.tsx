import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { type ReactNode } from "react"
import { Link, Navigate, Route, Routes, useLocation, useParams } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { authPrimaryButtonClass } from "../lib/buttonStyles"
import { isDesktopShell } from "../lib/desktopShell"
import { useT } from "../hooks/useT"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading } from "../components/Heading"
import { SyrusMark } from "../components/SyrusBrand"
import { LocationKeyedRouteErrorBoundary } from "../components/RouteErrorBoundary"
import { NotificationsRoute } from "../components/Notifications"
import { ConnectionStatusRoute } from "../components/ConnectionStatus"
import { useAppEvents } from "../lib/useAppEvents"
import { ConnectionContext } from "../lib/connectionContext"
import { AdminConsole } from "./AdminConsole"
import { AdminBackendExceptions } from "./AdminBackendExceptions"
import { AdminBrowserErrors } from "./AdminBrowserErrors"
import { AppChromeV2 } from "./AppChromeV2"
import { AdminGithubAppConfirm, AdminGithubAppRegister } from "./AdminGithubApp"
import { AdminInvitations } from "./AdminInvitations"
import { AdminInstallations } from "./AdminInstallations"
import { AdminOverview, AdminResourceAdmission, AdminScopedChatEvents } from "./AdminOverview"
import { AdminPluginDetail, AdminPlugins } from "./AdminPlugins"
import { AdminQueueRoute } from "./AdminQueue"
import { AdminReconcilerActivity } from "./AdminReconcilerActivity"
import { AdminWorkflowActivity } from "./AdminWorkflowActivity"
import { AdminWorkUnits } from "./AdminWorkUnits"
import { AdminMaintenanceTaskDetail, AdminMaintenanceTasks } from "./AdminMaintenanceTasks"
import { AdminProcessDetail, AdminProcessesIndex } from "./AdminProcesses"
import { AdminMcpToolUsage } from "./AdminMcpToolUsage"
import { AdminSettings } from "./AdminSettings"
import { RetentionSettings } from "./RetentionSettings"
import { AdminStuck } from "./AdminStuck"
import { AdminTranscript } from "./AdminTranscript"
import { AdminUserDetailRoute, AdminUsersIndex } from "./AdminUsers"
import { AdminTeamDetailRoute, AdminTeamsIndex } from "./AdminTeams"
import { AgentSettingsRoute } from "./AgentSettings"
import { PasswordRequestRoute, PasswordResetRoute, SignInRoute, SignUpRoute } from "./Auth"
import { ChatSearchRoute } from "./ChatSearch"
import { ChatRoute, SharedChatRoute } from "./Chat"
import { CredentialsRoute } from "./Credentials"
import { DashboardRoute } from "./Dashboard"
import { DesignSystemRoute } from "./DesignSystem"
import { DirectJobNewRoute } from "./DirectJobNew"
import { AdminFeatures } from "./AdminFeatures"
import { EpicDetailRoute } from "./EpicDetail"
import { EpicFormRoute } from "./EpicForm"
import { HiddenChatsRoute } from "./HiddenChats"
import { JobDetailRoute } from "./JobDetail"
import { NotificationsSettingsRoute } from "./NotificationsSettings"
import { OnboardingRoute } from "./Onboarding"
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import { AccountProfileRoute } from "./Profile"
import { PreferencesRoute } from "./Preferences"
import { RepositoriesIndex } from "./Repositories"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import { RepositoryCognitiveDebtRoute } from "./RepositoryCognitiveDebt"
import { RepositoryDocumentsRoute } from "./RepositoryDocuments"
import { RepositoryFormRoute } from "./RepositoryForm"
import { RepositoryHealthRoute } from "./RepositoryHealth"
import { RepositorySkillNewRoute } from "./RepositorySkillNew"
import { RepositoryTargetGraphRoute } from "./RepositoryTargetGraph"
import { Tags } from "./Tags"
import { ConnectedPlatformsRoute } from "./ConnectedPlatforms"
import { ThemesSettingsRoute } from "./ThemesSettings"
import { PluginAdminPageRoute } from "../pluginAdminPages"
import { PluginRepoPageTabRoute } from "../pluginRepoPageTabs"
import { PluginSidebarPageRoute, usePluginSidebarPaths } from "../pluginSidebarPages"
import { isAuthPath } from "./appChromeV2/helpers"
import { fetchSidebarPluginPages } from "../api/sidebarPages"
import { AdminPluginServices } from "@plugins/plugin_runtime/app/frontend/routes/AdminPluginServices"

type AppRouteDefinition = {
  path: string
  element: ReactNode
}

const appRouteDefinitions: AppRouteDefinition[] = [
  { path: "/session/new", element: <SignInRoute /> },
  { path: "/users/new", element: <SignUpRoute /> },
  { path: "/passwords/new", element: <PasswordRequestRoute /> },
  { path: "/passwords/:token/edit", element: <PasswordResetRoute /> },
  { path: "/dashboard", element: <DashboardRoute /> },
  { path: "/dashboard/epics", element: <DashboardRoute /> },
  { path: "/dashboard/jobs", element: <DashboardRoute /> },
  { path: "/dashboard/workflows", element: <DashboardRoute /> },
  { path: "/notifications", element: <NotificationsRoute /> },
  { path: "/connection", element: <ConnectionStatusRoute /> },
  { path: "/setup", element: <SetupRedirect /> },
  { path: "/admin", element: <AdminOverview /> },
  { path: "/admin/resource_admission", element: <AdminResourceAdmission /> },
  { path: "/admin/scoped_chat_events", element: <AdminScopedChatEvents /> },
  { path: "/admin/queue", element: <AdminQueueRoute /> },
  { path: "/admin/queue/:tab", element: <AdminQueueRoute /> },
  { path: "/admin/stuck", element: <AdminStuck /> },
  { path: "/admin/activity", element: <AdminWorkflowActivity /> },
  { path: "/admin/work_units", element: <AdminWorkUnits /> },
  { path: "/admin/maintenance_tasks", element: <AdminMaintenanceTasks /> },
  { path: "/admin/maintenance_tasks/:id", element: <AdminMaintenanceTaskDetail /> },
  { path: "/admin/reconciler_activity", element: <AdminReconcilerActivity /> },
  { path: "/admin/browser_errors", element: <AdminBrowserErrors /> },
  { path: "/admin/backend_exceptions", element: <AdminBackendExceptions /> },
  { path: "/admin/plugins", element: <AdminPlugins /> },
  { path: "/admin/plugins/:name", element: <AdminPluginDetail /> },
  { path: "/admin/plugin_services", element: <AdminPluginServices /> },
  { path: "/admin/processes", element: <AdminProcessesIndex /> },
  { path: "/admin/processes/:id", element: <AdminProcessDetail /> },
  { path: "/admin/mcp_tool_usage", element: <AdminMcpToolUsage /> },
  { path: "/admin/runs/:runId/transcript", element: <AdminTranscript /> },
  { path: "/admin/users", element: <AdminUsersIndex /> },
  { path: "/admin/users/:id", element: <AdminUserDetailRoute /> },
  { path: "/admin/teams", element: <AdminTeamsIndex /> },
  { path: "/admin/teams/:id", element: <AdminTeamDetailRoute /> },
  { path: "/admin/console", element: <AdminConsole /> },
  { path: "/admin/installations", element: <AdminInstallations /> },
  { path: "/admin/github_app/register", element: <AdminGithubAppRegister /> },
  { path: "/admin/github_app/confirm", element: <AdminGithubAppConfirm /> },
  { path: "/admin/features", element: <AdminFeatures /> },
  { path: "/admin/retention_settings", element: <RetentionSettings /> },
  { path: "/admin/*", element: <PluginAdminPageRoute /> },
  { path: "/invitations", element: <AdminInvitations /> },
  { path: "/settings/edit", element: <AdminSettings /> },
  { path: "/settings", element: <SettingsSectionRoute><AccountProfileRoute /></SettingsSectionRoute> },
  { path: "/profile", element: <SettingsSectionRoute><AccountProfileRoute /></SettingsSectionRoute> },
  { path: "/credentials", element: <SettingsSectionRoute><CredentialsRoute /></SettingsSectionRoute> },
  { path: "/settings/hidden_chats", element: <SettingsSectionRoute><HiddenChatsRoute /></SettingsSectionRoute> },
  { path: "/credentials/edit", element: <SettingsSectionRoute><CredentialsRoute /></SettingsSectionRoute> },
  { path: "/settings/agent", element: <SettingsSectionRoute><AgentSettingsRoute /></SettingsSectionRoute> },
  { path: "/settings/preferences", element: <SettingsSectionRoute><PreferencesRoute /></SettingsSectionRoute> },
  { path: "/notifications/settings", element: <SettingsSectionRoute><NotificationsSettingsRoute /></SettingsSectionRoute> },
  { path: "/settings/themes", element: <SettingsSectionRoute><ThemesSettingsRoute /></SettingsSectionRoute> },
  { path: "/settings/connected_platforms", element: <SettingsSectionRoute><ConnectedPlatformsRoute /></SettingsSectionRoute> },
  { path: "/documents", element: <SettingsSectionRoute><PersonalDocumentsRoute /></SettingsSectionRoute> },
  { path: "/tags", element: <SettingsSectionRoute><Tags /></SettingsSectionRoute> },
  { path: "/design_system", element: <SettingsSectionRoute><DesignSystemRoute /></SettingsSectionRoute> },
  { path: "/repositories/:repositoryId/skills/new", element: <RepositorySkillNewRoute /> },
  { path: "/repositories/:repositoryId/health", element: <RepositoryHealthRoute /> },
  { path: "/repositories/:repositoryId/cognitive_debt", element: <RepositoryCognitiveDebtRoute /> },
  { path: "/repositories/:repositoryId/documents", element: <RepositoryDocumentsRoute /> },
  { path: "/repositories/:repositoryId/memberships", element: <RepositoryMembershipsRedirect /> },
  { path: "/repositories/:repositoryId/target_graph", element: <RepositoryTargetGraphRoute /> },
  { path: "/repositories/:repositoryId/plugin/*", element: <PluginRepoPageTabRoute /> },
  { path: "/repositories/new", element: <RepositoryFormRoute mode="new" /> },
  { path: "/repositories/:id/edit", element: <RepositoryFormRoute mode="edit" /> },
  { path: "/repositories/:id", element: <RepositoryDetailRoute /> },
  { path: "/repositories", element: <RepositoriesIndex /> },
  { path: "/jobs", element: <DashboardRoute /> },
  { path: "/jobs/new", element: <DirectJobNewRoute /> },
  { path: "/jobs/:id/source", element: <JobDetailRoute /> },
  { path: "/jobs/:id", element: <JobDetailRoute /> },
  { path: "/epics/new", element: <EpicFormRoute mode="new" /> },
  { path: "/epics/:id/edit", element: <EpicFormRoute mode="edit" /> },
  { path: "/epics/:id", element: <EpicDetailRoute /> },
  { path: "/chats/search", element: <ChatSearchRoute /> },
  { path: "/chats/shared/:token", element: <SharedChatRoute /> },
  { path: "/chats/:id", element: <ChatRoute /> }
]

export function App() {
  const { isDisconnected, status, events, justReconnected, reconnectAt, clearReconnected } = useAppEvents()
  const initialBootstrap = readInitialBootstrap()
  const { t } = useT("nav")

  return (
    <ConnectionContext.Provider value={{ isDisconnected, status, reconnectAt, events }}>
      <AppShell initialBootstrap={initialBootstrap} />
      {justReconnected ? (
        <NoticeToast onDismiss={clearReconnected} message={t("connection_status.reconnected_toast")} />
      ) : null}
    </ConnectionContext.Provider>
  )
}

function AppShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const routes = (
    <Routes>
      <Route path="/" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      <Route path="/app-shell" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      {renderAppRoutes(initialBootstrap)}
      {renderPluginSidebarRoutes(initialBootstrap)}
      <Route path="*" element={<BootstrapShell initialBootstrap={initialBootstrap} />} />
    </Routes>
  )

  return <AppChromeV2 initialBootstrap={initialBootstrap}>{routes}</AppChromeV2>
}

function RootRoute({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const { t } = useT("common")
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  if (bootstrap.isPending) {
    return <main aria-label={t("app_name")} className="p-6 text-sm text-gray-600">{t("loading")}</main>
  }

  if (bootstrap.isError) {
    return (
      <main aria-label={t("app_name")} className="p-6">
        <p className="text-sm text-red-700">{t("shell.load_error_instance")}</p>
      </main>
    )
  }

  if (bootstrap.data.current_user) {
    // Lock the root to onboarding only until the onboarding chat begins; after
    // that the operator can roam even before the first Epic lands.
    const setup = bootstrap.data.setup_status
    if (setup && !setup.first_epic_landed && !setup.onboarding_chat_started) {
      return <Navigate replace to="/onboarding" />
    }

    return <DashboardRoute />
  }

  return <PublicLanding payload={bootstrap.data} />
}

function PublicLanding({ payload }: { payload: BootstrapPayload }) {
  const { t } = useT("landing")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const invitationToken = new URLSearchParams(location.search).get("token")?.trim()
  const cta = publicCta(payload.public, prefix, invitationToken, t)
  // No "Sign in" when sign-ups are locked, or when no users exist yet (the
  // first account is created via "Set up this Syrus instance" — there is
  // nobody to sign in as).
  const showSignIn = cta.kind !== "locked" && cta.kind !== "first"
  const signInPath = withRoutePrefix(payload.public.sign_in_path, prefix)
  const accessPageClass = "flex min-h-[100dvh] items-center justify-center bg-gray-50 px-5 py-10 text-gray-950 dark:bg-gray-950 dark:text-white"
  const accessCardClass = "w-full max-w-md rounded-lg border border-gray-200 bg-white px-6 py-8 text-center shadow-sm dark:border-gray-800 dark:bg-gray-900 sm:px-10 sm:py-10"

  // Inside the desktop shell the app is already installed and pointed at an
  // instance, so a merely signed-out user should land on sign-in (or the
  // invite/open signup page — on open-signup instances the landing was the
  // only path to signup, and SignUp links back to sign-in), never the
  // self-hosting marketing pitch. First run keeps the welcome below — it
  // doubles as the desktop first-run screen.
  if (isDesktopShell() && cta.kind !== "first") {
    return <Navigate replace to={cta.kind === "invite" || cta.kind === "open" ? cta.href : signInPath} />
  }

  return (
    <main aria-label={cta.kind === "first" ? t("aria_first_run") : t("aria_public")} className={accessPageClass}>
      <section className={accessCardClass} aria-label={t("aria_instance_access")}>
        <SyrusMark className="mx-auto h-14 w-14" />
        <PageHeading className="mt-4">{t("name")}</PageHeading>
        <h2 className="mt-7 text-xl font-semibold">{cta.label}</h2>
        <p className="mt-3 text-sm leading-6 text-gray-600 dark:text-gray-400">{cta.description}</p>
        <div className="mt-7 flex flex-col items-stretch gap-3">
          <Link className={authPrimaryButtonClass} to={cta.href}>{cta.label}</Link>
          {showSignIn ? <Link className={landingSecondaryButtonClass()} to={signInPath}>{t("sign_in")}</Link> : null}
        </div>
      </section>
    </main>
  )
}

function publicCta(publicState: BootstrapPayload["public"], prefix: string, invitationToken: string | undefined, t: (key: string) => string) {
  if (publicState.first_signup) {
    return {
      kind: "first" as const,
      href: withRoutePrefix(publicState.signup_path, prefix),
      label: t("cta_first_label"),
      description: t("cta_first_desc")
    }
  }

  if (invitationToken) {
    return {
      kind: "invite" as const,
      href: `${withRoutePrefix(publicState.signup_path, prefix)}?token=${encodeURIComponent(invitationToken)}`,
      label: t("cta_invite_label"),
      description: t("cta_invite_desc")
    }
  }

  if (publicState.signups_open) {
    return {
      kind: "open" as const,
      href: withRoutePrefix(publicState.signup_path, prefix),
      label: t("cta_open_label"),
      description: t("cta_open_desc")
    }
  }

  return {
    kind: "locked" as const,
    href: withRoutePrefix(publicState.sign_in_path, prefix),
    label: t("cta_locked_label"),
    description: t("cta_locked_desc")
  }
}

function renderAppRoutes(initialBootstrap: BootstrapPayload | null) {
  return appRouteDefinitions.flatMap(({ path, element }) => [
    <Route element={<LocationKeyedRouteErrorBoundary>{element}</LocationKeyedRouteErrorBoundary>} key={path} path={path} />,
    <Route element={<LocationKeyedRouteErrorBoundary>{element}</LocationKeyedRouteErrorBoundary>} key={`/app-shell${path}`} path={`/app-shell${path}`} />
  ]).concat([
    <Route element={<OnboardingShell initialBootstrap={initialBootstrap} />} key="/onboarding" path="/onboarding" />,
    <Route element={<OnboardingShell initialBootstrap={initialBootstrap} />} key="/app-shell/onboarding" path="/app-shell/onboarding" />
  ])
}

// /setup is retired — it now just lands the operator on the onboarding page.
function SetupRedirect() {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  return <Navigate replace to={`${prefix}/onboarding`} />
}

// The standalone Members tab/page was retired -- member management now
// lives on the repository edit page. Keep this redirect so old links and
// bookmarks to /repositories/:id/memberships still land somewhere useful.
function RepositoryMembershipsRedirect() {
  const location = useLocation()
  const params = useParams()
  const prefix = routePrefix(location.pathname)
  return <Navigate replace to={withRoutePrefix(`/repositories/${params.repositoryId}/edit`, prefix)} />
}

function OnboardingShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  return <OnboardingRoute bootstrap={bootstrap.data ?? initialBootstrap} />
}

/**
 * Real routes for whatever paths plugins have claimed, built from the
 * `sidebar_page` declarations rather than from a list kept here.
 *
 * This is why core carries no plugin paths: a plugin says where it lives, and
 * core only has to know that plugins may own URLs at all. Adding a plugin page
 * -- or a new plugin -- needs no edit to this file.
 *
 * Declared last so every core route still wins on a collision, and left out
 * entirely until the declarations arrive, so an unclaimed URL keeps falling to
 * the shell exactly as before.
 */
function renderPluginSidebarRoutes(initialBootstrap: BootstrapPayload | null) {
  const location = useLocation()
  const normalizedPath = normalizedAppPath(location.pathname)
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: initialBootstrap == null && !isAuthPath(normalizedPath),
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const user = (bootstrap.data ?? initialBootstrap)?.current_user
  const shouldLoadPluginRoutes = Boolean(user) && !isAuthPath(normalizedPath)
  const paths = usePluginSidebarPaths({ enabled: shouldLoadPluginRoutes })

  return paths.flatMap(({ path, section }) => {
    const element = section === "settings"
      ? <SettingsSectionRoute><PluginSidebarPageRoute /></SettingsSectionRoute>
      : <PluginSidebarPageRoute />

    // Both variants, the same way renderAppRoutes registers core routes: the
    // shell serves every page under /app-shell as well, and a plugin page that
    // only registered the bare path is unreachable there.
    return [
      <Route element={element} key={path} path={path} />,
      <Route element={element} key={`/app-shell${path}`} path={`/app-shell${path}`} />
    ]
  })
}

function SettingsSectionRoute({ children }: { children: ReactNode }) {
  const { t: tCommon } = useT("common")
  const { t } = useT("settings")
  const { t: tNav } = useT("nav")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)
  // Plugins can own a settings page (agent memory, say); they declare
  // section "settings" on their sidebar_page metadata.
  const pluginPages = useQuery({
    queryKey: ["sidebar", "plugin_pages"],
    queryFn: fetchSidebarPluginPages,
    staleTime: 30_000
  })
  const pluginSettingsItems = (pluginPages.data?.pages ?? [])
    .filter((page) => page.section === "settings")
    .map((page) => ({
      key: page.id,
      label: page.label_key ? tNav(page.label_key, { defaultValue: page.label }) : page.label,
      path: page.path,
      active: (path: string) => page.paths.some((candidate) => path === candidate),
      groupId: null
    }))

  const { groups, ungrouped } = groupSettingsNavItems(settingsNavigationItems(t, pluginSettingsItems))

  return (
    <div className="flex min-h-full flex-col bg-gray-50 dark:bg-gray-900 lg:flex-row">
      <aside className="shrink-0 border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950 lg:w-56 lg:border-b-0 lg:border-r">
        <nav aria-label={tCommon("shell.settings_nav_aria")} className="scroll-fade-x flex gap-4 overflow-x-auto px-4 py-3 text-sm lg:flex-col lg:gap-4 lg:overflow-visible lg:p-4 lg:[mask-image:none] lg:[-webkit-mask-image:none]">
          {groups.map(({ group, items }) => (
            <div className="flex shrink-0 items-center gap-2 lg:block lg:shrink" key={group.id}>
              <p className="hidden px-2.5 text-xs font-semibold uppercase tracking-wider text-text-muted lg:mb-1 lg:block">
                {t(group.labelKey)}
              </p>
              <div className="flex gap-2 lg:flex-col lg:gap-0.5">
                {items.map((item) => (
                  <Link className={settingsSideNavLinkClass(item.active(normalizedPath))} key={item.key} to={withRoutePrefix(item.path, prefix)}>
                    {item.label}
                  </Link>
                ))}
              </div>
            </div>
          ))}
          {ungrouped.length > 0 && (
            <div className="flex shrink-0 gap-2 lg:flex-col lg:gap-0.5">
              {ungrouped.map((item) => (
                <Link className={settingsSideNavLinkClass(item.active(normalizedPath))} key={item.key} to={withRoutePrefix(item.path, prefix)}>
                  {item.label}
                </Link>
              ))}
            </div>
          )}
        </nav>
      </aside>
      <div className="min-w-0 flex-1">
        {children}
      </div>
    </div>
  )
}

type SettingsNavigationItem = { key: string; label: string; path: string; active: (path: string) => boolean; groupId: string | null }
type SettingsNavGroup = { id: string; labelKey: string }

// Mirrors Admin nav's grouping pattern (app/frontend/routes/appChromeV2/adminNav.ts):
// account-configuration items cluster separately from product-feature settings,
// workspace/library content (Documents, Tags), and external-platform integrations.
// Plugin-owned settings pages have no group signal yet, so they render as a
// trailing ungrouped cluster, same as adminNav's ungroupedExtensions.
const SETTINGS_NAV_GROUPS: readonly SettingsNavGroup[] = [
  { id: "account", labelKey: "nav_groups.account" },
  { id: "product", labelKey: "nav_groups.product" },
  { id: "workspace", labelKey: "nav_groups.workspace" },
  { id: "integrations", labelKey: "nav_groups.integrations" }
]

function settingsNavigationItems(
  t: (key: string) => string,
  pluginItems: SettingsNavigationItem[] = []
): SettingsNavigationItem[] {
  const items: SettingsNavigationItem[] = [
    { key: "profile", label: t("nav.profile"), path: "/profile", active: (path) => path === "/settings" || path === "/profile", groupId: "account" },
    { key: "credentials", label: t("nav.credentials"), path: "/credentials", active: (path) => path === "/credentials" || path === "/credentials/edit", groupId: "account" },
    { key: "agent_settings", label: t("nav.agent_settings"), path: "/settings/agent", active: (path) => path === "/settings/agent", groupId: "account" },
    { key: "preferences", label: t("nav.preferences"), path: "/settings/preferences", active: (path) => path === "/settings/preferences", groupId: "account" },
    { key: "notifications", label: t("nav.notifications"), path: "/notifications/settings", active: (path) => path === "/notifications/settings", groupId: "product" },
    { key: "themes", label: t("nav.themes"), path: "/settings/themes", active: (path) => path === "/settings/themes", groupId: "product" },
    { key: "hidden_chats", label: t("nav.hidden_chats"), path: "/settings/hidden_chats", active: (path) => path === "/settings/hidden_chats", groupId: "product" },
    { key: "documents", label: t("nav.documents"), path: "/documents", active: (path) => path === "/documents", groupId: "workspace" },
    { key: "tags", label: t("nav.tags"), path: "/tags", active: (path) => path === "/tags", groupId: "workspace" },
    { key: "connected_platforms", label: t("nav.connected_platforms"), path: "/settings/connected_platforms", active: (path) => path === "/settings/connected_platforms", groupId: "integrations" }
  ]

  return [ ...items, ...pluginItems ]
}

function groupSettingsNavItems(items: SettingsNavigationItem[]) {
  const groups = SETTINGS_NAV_GROUPS
    .map((group) => ({ group, items: items.filter((item) => item.groupId === group.id) }))
    .filter(({ items }) => items.length > 0)
  const ungrouped = items.filter((item) => item.groupId == null)

  return { groups, ungrouped }
}

function normalizedAppPath(pathname: string) {
  return pathname.replace(/^\/app-shell/, "") || "/"
}

function BootstrapShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const { t } = useT("common")
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  if (bootstrap.isPending) {
    return <main aria-label={t("shell.spa_aria")} className="p-6 text-sm text-gray-600">{t("loading")}</main>
  }

  if (bootstrap.isError) {
    return (
      <main aria-label={t("shell.spa_aria")} className="p-6">
        <p className="text-sm text-red-700">{t("shell.load_error")}</p>
      </main>
    )
  }

  // `app` is read defensively because this component is the catch-all's
  // element: it renders for any URL nothing else claimed, including -- for a
  // frame -- one a plugin route is about to claim. Crashing here would take
  // the whole SPA down over a field this page only uses to print a revision.
  const { current_user: user, app } = bootstrap.data ?? {}

  return (
    <main aria-label={t("shell.spa_aria")} className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500">{t("shell.react_shell")}</p>
        <PageHeading className="mt-1">{t("app_name")}</PageHeading>
      </header>

      <section className="grid gap-4 sm:grid-cols-2">
        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">{t("shell.signed_in")}</h2>
          <p className="mt-2 text-sm text-gray-700">{user?.display_name || t("shell.not_signed_in")}</p>
          {user ? <p className="text-xs text-gray-500">{user.email_address}</p> : null}
        </div>

        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">{t("shell.revision")}</h2>
          <p className="mt-2 font-mono text-sm text-gray-700">{app?.revision}</p>
          {app?.revision_url ? (
            <a className="text-xs text-brand underline hover:no-underline" href={app.revision_url}>
              {t("shell.view_commit")}
            </a>
          ) : null}
        </div>
      </section>
    </main>
  )
}

function landingSecondaryButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3.5 py-2.5 text-sm font-semibold text-gray-800 hover:bg-gray-50"
}

function settingsSideNavLinkClass(active: boolean) {
  return `whitespace-nowrap rounded px-3 py-2 font-medium ${active ? "bg-brand/10 text-brand" : "text-gray-700 hover:bg-gray-100 hover:text-brand dark:text-gray-300 dark:hover:bg-gray-800"}`
}
