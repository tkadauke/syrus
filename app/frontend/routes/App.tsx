import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { lazy, Suspense, type ReactNode } from "react"
import { Link, Navigate, Route, Routes, useLocation, useParams } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { authPrimaryButtonClass } from "../lib/buttonStyles"
import { isDesktopShell } from "../lib/desktopShell"
import { useT } from "../hooks/useT"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading } from "../components/Heading"
import { SyrusMark } from "../components/SyrusBrand"
import { LocationKeyedRouteErrorBoundary } from "../components/RouteErrorBoundary"
import { useAppEvents } from "../lib/useAppEvents"
import { ConnectionContext } from "../lib/connectionContext"
import { AppChromeV2 } from "./AppChromeV2"
import { PasswordRequestRoute, PasswordResetRoute, SignInRoute, SignUpRoute } from "./Auth"
import { PluginAdminPageRoute } from "../pluginAdminPages"
import { PluginRepoPageTabRoute } from "../pluginRepoPageTabs"
import { PluginSidebarPageRoute, usePluginSidebarPaths } from "../pluginSidebarPages"
import { isAuthPath } from "./appChromeV2/helpers"
import { fetchSidebarPluginPages } from "../api/sidebarPages"
import { UiEngagementTelemetry } from "../lib/uiEngagement"

const AccountProfileRoute = lazy(() => import("./Profile").then((module) => ({ default: module.AccountProfileRoute })))
const AdminBackendExceptions = lazy(() => import("./AdminBackendExceptions").then((module) => ({ default: module.AdminBackendExceptions })))
const AdminBrowserErrors = lazy(() => import("./AdminBrowserErrors").then((module) => ({ default: module.AdminBrowserErrors })))
const AdminConsole = lazy(() => import("./AdminConsole").then((module) => ({ default: module.AdminConsole })))
const AdminFeatures = lazy(() => import("./AdminFeatures").then((module) => ({ default: module.AdminFeatures })))
const AdminGithubAppConfirm = lazy(() => import("./AdminGithubApp").then((module) => ({ default: module.AdminGithubAppConfirm })))
const AdminGithubAppRegister = lazy(() => import("./AdminGithubApp").then((module) => ({ default: module.AdminGithubAppRegister })))
const AdminInstallations = lazy(() => import("./AdminInstallations").then((module) => ({ default: module.AdminInstallations })))
const AdminInvitations = lazy(() => import("./AdminInvitations").then((module) => ({ default: module.AdminInvitations })))
const AdminMaintenanceTaskDetail = lazy(() => import("./AdminMaintenanceTasks").then((module) => ({ default: module.AdminMaintenanceTaskDetail })))
const AdminMaintenanceTasks = lazy(() => import("./AdminMaintenanceTasks").then((module) => ({ default: module.AdminMaintenanceTasks })))
const AdminMcpToolUsage = lazy(() => import("./AdminMcpToolUsage").then((module) => ({ default: module.AdminMcpToolUsage })))
const AdminOverview = lazy(() => import("./AdminOverview").then((module) => ({ default: module.AdminOverview })))
const AdminPluginDetail = lazy(() => import("./AdminPlugins").then((module) => ({ default: module.AdminPluginDetail })))
const AdminPlugins = lazy(() => import("./AdminPlugins").then((module) => ({ default: module.AdminPlugins })))
const AdminPluginServices = lazy(() => import("@plugins/plugin_runtime/app/frontend/routes/AdminPluginServices").then((module) => ({ default: module.AdminPluginServices })))
const AdminProcessDetail = lazy(() => import("./AdminProcesses").then((module) => ({ default: module.AdminProcessDetail })))
const AdminProcessesIndex = lazy(() => import("./AdminProcesses").then((module) => ({ default: module.AdminProcessesIndex })))
const AdminQueueRoute = lazy(() => import("./AdminQueue").then((module) => ({ default: module.AdminQueueRoute })))
const AdminReconcilerActivity = lazy(() => import("./AdminReconcilerActivity").then((module) => ({ default: module.AdminReconcilerActivity })))
const AdminResourceAdmission = lazy(() => import("./AdminOverview").then((module) => ({ default: module.AdminResourceAdmission })))
const AdminScopedChatEvents = lazy(() => import("./AdminOverview").then((module) => ({ default: module.AdminScopedChatEvents })))
const AdminSettings = lazy(() => import("./AdminSettings").then((module) => ({ default: module.AdminSettings })))
const AdminStuck = lazy(() => import("./AdminStuck").then((module) => ({ default: module.AdminStuck })))
const AdminTeamDetailRoute = lazy(() => import("./AdminTeams").then((module) => ({ default: module.AdminTeamDetailRoute })))
const AdminTeamsIndex = lazy(() => import("./AdminTeams").then((module) => ({ default: module.AdminTeamsIndex })))
const AdminTranscript = lazy(() => import("./AdminTranscript").then((module) => ({ default: module.AdminTranscript })))
const AdminUserDetailRoute = lazy(() => import("./AdminUsers").then((module) => ({ default: module.AdminUserDetailRoute })))
const AdminUsersIndex = lazy(() => import("./AdminUsers").then((module) => ({ default: module.AdminUsersIndex })))
const AdminWorkflowActivity = lazy(() => import("./AdminWorkflowActivity").then((module) => ({ default: module.AdminWorkflowActivity })))
const AdminWorkUnits = lazy(() => import("./AdminWorkUnits").then((module) => ({ default: module.AdminWorkUnits })))
const AgentSettingsRoute = lazy(() => import("./AgentSettings").then((module) => ({ default: module.AgentSettingsRoute })))
const ChatRoute = lazy(() => import("./Chat").then((module) => ({ default: module.ChatRoute })))
const ChatSearchRoute = lazy(() => import("./ChatSearch").then((module) => ({ default: module.ChatSearchRoute })))
const ConnectedPlatformsRoute = lazy(() => import("./ConnectedPlatforms").then((module) => ({ default: module.ConnectedPlatformsRoute })))
const ConnectionStatusRoute = lazy(() => import("../components/ConnectionStatus").then((module) => ({ default: module.ConnectionStatusRoute })))
const CredentialsRoute = lazy(() => import("./Credentials").then((module) => ({ default: module.CredentialsRoute })))
const DashboardRoute = lazy(() => import("./Dashboard").then((module) => ({ default: module.DashboardRoute })))
const DesignSystemRoute = lazy(() => import("./DesignSystem").then((module) => ({ default: module.DesignSystemRoute })))
const DirectJobNewRoute = lazy(() => import("./DirectJobNew").then((module) => ({ default: module.DirectJobNewRoute })))
const EpicDetailRoute = lazy(() => import("./EpicDetail").then((module) => ({ default: module.EpicDetailRoute })))
const EpicFormRoute = lazy(() => import("./EpicForm").then((module) => ({ default: module.EpicFormRoute })))
const HiddenChatsRoute = lazy(() => import("./HiddenChats").then((module) => ({ default: module.HiddenChatsRoute })))
const JobDetailRoute = lazy(() => import("./JobDetail").then((module) => ({ default: module.JobDetailRoute })))
const NotificationsRoute = lazy(() => import("../components/Notifications").then((module) => ({ default: module.NotificationsRoute })))
const NotificationsSettingsRoute = lazy(() => import("./NotificationsSettings").then((module) => ({ default: module.NotificationsSettingsRoute })))
const OnboardingRoute = lazy(() => import("./Onboarding").then((module) => ({ default: module.OnboardingRoute })))
const PersonalDocumentsRoute = lazy(() => import("./PersonalDocuments").then((module) => ({ default: module.PersonalDocumentsRoute })))
const PreferencesRoute = lazy(() => import("./Preferences").then((module) => ({ default: module.PreferencesRoute })))
const RepositoriesIndex = lazy(() => import("./Repositories").then((module) => ({ default: module.RepositoriesIndex })))
const RepositoryDetailRoute = lazy(() => import("./RepositoryDetail").then((module) => ({ default: module.RepositoryDetailRoute })))
const RepositoryCognitiveDebtRoute = lazy(() => import("./RepositoryCognitiveDebt").then((module) => ({ default: module.RepositoryCognitiveDebtRoute })))
const RepositoryDocumentsRoute = lazy(() => import("./RepositoryDocuments").then((module) => ({ default: module.RepositoryDocumentsRoute })))
const RepositoryFormRoute = lazy(() => import("./RepositoryForm").then((module) => ({ default: module.RepositoryFormRoute })))
const RepositoryHealthRoute = lazy(() => import("./RepositoryHealth").then((module) => ({ default: module.RepositoryHealthRoute })))
const RepositorySkillNewRoute = lazy(() => import("./RepositorySkillNew").then((module) => ({ default: module.RepositorySkillNewRoute })))
const RepositoryTargetGraphRoute = lazy(() => import("./RepositoryTargetGraph").then((module) => ({ default: module.RepositoryTargetGraphRoute })))
const RetentionSettings = lazy(() => import("./RetentionSettings").then((module) => ({ default: module.RetentionSettings })))
const SharedChatRoute = lazy(() => import("./Chat").then((module) => ({ default: module.SharedChatRoute })))
const Tags = lazy(() => import("./Tags").then((module) => ({ default: module.Tags })))
const ThemesSettingsRoute = lazy(() => import("./ThemesSettings").then((module) => ({ default: module.ThemesSettingsRoute })))

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
  {
    path: "/settings",
    element: (
      <SettingsSectionRoute>
        <AccountProfileRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/profile",
    element: (
      <SettingsSectionRoute>
        <AccountProfileRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/credentials",
    element: (
      <SettingsSectionRoute>
        <CredentialsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/settings/hidden_chats",
    element: (
      <SettingsSectionRoute>
        <HiddenChatsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/credentials/edit",
    element: (
      <SettingsSectionRoute>
        <CredentialsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/settings/agent",
    element: (
      <SettingsSectionRoute>
        <AgentSettingsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/settings/preferences",
    element: (
      <SettingsSectionRoute>
        <PreferencesRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/notifications/settings",
    element: (
      <SettingsSectionRoute>
        <NotificationsSettingsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/settings/themes",
    element: (
      <SettingsSectionRoute>
        <ThemesSettingsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/settings/connected_platforms",
    element: (
      <SettingsSectionRoute>
        <ConnectedPlatformsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/documents",
    element: (
      <SettingsSectionRoute>
        <PersonalDocumentsRoute />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/tags",
    element: (
      <SettingsSectionRoute>
        <Tags />
      </SettingsSectionRoute>
    )
  },
  {
    path: "/design_system",
    element: (
      <SettingsSectionRoute>
        <DesignSystemRoute />
      </SettingsSectionRoute>
    )
  },
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
      {justReconnected ? <NoticeToast onDismiss={clearReconnected} message={t("connection_status.reconnected_toast")} /> : null}
    </ConnectionContext.Provider>
  )
}

function AppShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const routes = (
    <Routes>
      <Route path="/" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      <Route path="/app-shell" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      {renderAppRoutes(initialBootstrap)}
      {renderPluginSidebarRoutes(initialBootstrap)}
      <Route path="*" element={<BootstrapShell initialBootstrap={initialBootstrap} />} />
    </Routes>
  )

  return (
    <AppChromeV2 initialBootstrap={initialBootstrap}>
      <UiEngagementTelemetry enabled={Boolean(bootstrap.data?.app?.ui_engagement_telemetry_enabled)} />
      {routes}
    </AppChromeV2>
  )
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
    return (
      <main aria-label={t("app_name")} className="p-6 text-sm text-gray-600">
        {t("loading")}
      </main>
    )
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

    return <LazyRouteBoundary><DashboardRoute /></LazyRouteBoundary>
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
  const accessCardClass =
    "w-full max-w-md rounded-lg border border-gray-200 bg-white px-6 py-8 text-center shadow-sm dark:border-gray-800 dark:bg-gray-900 sm:px-10 sm:py-10"

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
          <Link className={authPrimaryButtonClass} to={cta.href}>
            {cta.label}
          </Link>
          {showSignIn ? (
            <Link className={landingSecondaryButtonClass()} to={signInPath}>
              {t("sign_in")}
            </Link>
          ) : null}
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
    <Route element={<LazyRouteBoundary key={path}>{element}</LazyRouteBoundary>} key={path} path={path} />,
    <Route element={<LazyRouteBoundary key={`/app-shell${path}`}>{element}</LazyRouteBoundary>} key={`/app-shell${path}`} path={`/app-shell${path}`} />
  ]).concat([
    <Route element={<LazyRouteBoundary><OnboardingShell initialBootstrap={initialBootstrap} /></LazyRouteBoundary>} key="/onboarding" path="/onboarding" />,
    <Route element={<LazyRouteBoundary><OnboardingShell initialBootstrap={initialBootstrap} /></LazyRouteBoundary>} key="/app-shell/onboarding" path="/app-shell/onboarding" />
  ])
}

export function LazyRouteBoundary({ children }: { children: ReactNode }) {
  return (
    <LocationKeyedRouteErrorBoundary>
      <Suspense fallback={<RouteLoadingFallback />}>
        {children}
      </Suspense>
    </LocationKeyedRouteErrorBoundary>
  )
}

function RouteLoadingFallback() {
  const { t } = useT("common")
  return (
    <main aria-label={t("app_name")} className="p-6 text-sm text-gray-600 dark:text-gray-400">
      <p role="status">{t("loading")}</p>
    </main>
  )
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
      ? <LazyRouteBoundary><SettingsSectionRoute><PluginSidebarPageRoute /></SettingsSectionRoute></LazyRouteBoundary>
      : <LazyRouteBoundary><PluginSidebarPageRoute /></LazyRouteBoundary>

    // Both variants, the same way renderAppRoutes registers core routes: the
    // shell serves every page under /app-shell as well, and a plugin page that
    // only registered the bare path is unreachable there.
    return [<Route element={element} key={path} path={path} />, <Route element={element} key={`/app-shell${path}`} path={`/app-shell${path}`} />]
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
        <nav
          aria-label={tCommon("shell.settings_nav_aria")}
          className="scroll-fade-x flex gap-4 overflow-x-auto px-4 py-3 text-sm lg:flex-col lg:gap-4 lg:overflow-visible lg:p-4 lg:[mask-image:none] lg:[-webkit-mask-image:none]"
        >
          {groups.map(({ group, items }) => (
            <div className="flex shrink-0 items-center gap-2 lg:block lg:shrink" key={group.id}>
              <p className="hidden px-2.5 text-xs font-semibold uppercase tracking-wider text-text-muted lg:mb-1 lg:block">{t(group.labelKey)}</p>
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
      <div className="min-w-0 flex-1">{children}</div>
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

function settingsNavigationItems(t: (key: string) => string, pluginItems: SettingsNavigationItem[] = []): SettingsNavigationItem[] {
  const items: SettingsNavigationItem[] = [
    { key: "profile", label: t("nav.profile"), path: "/profile", active: (path) => path === "/settings" || path === "/profile", groupId: "account" },
    {
      key: "credentials",
      label: t("nav.credentials"),
      path: "/credentials",
      active: (path) => path === "/credentials" || path === "/credentials/edit",
      groupId: "account"
    },
    { key: "agent_settings", label: t("nav.agent_settings"), path: "/settings/agent", active: (path) => path === "/settings/agent", groupId: "account" },
    { key: "preferences", label: t("nav.preferences"), path: "/settings/preferences", active: (path) => path === "/settings/preferences", groupId: "account" },
    {
      key: "notifications",
      label: t("nav.notifications"),
      path: "/notifications/settings",
      active: (path) => path === "/notifications/settings",
      groupId: "product"
    },
    { key: "themes", label: t("nav.themes"), path: "/settings/themes", active: (path) => path === "/settings/themes", groupId: "product" },
    {
      key: "hidden_chats",
      label: t("nav.hidden_chats"),
      path: "/settings/hidden_chats",
      active: (path) => path === "/settings/hidden_chats",
      groupId: "product"
    },
    { key: "documents", label: t("nav.documents"), path: "/documents", active: (path) => path === "/documents", groupId: "workspace" },
    { key: "tags", label: t("nav.tags"), path: "/tags", active: (path) => path === "/tags", groupId: "workspace" },
    {
      key: "connected_platforms",
      label: t("nav.connected_platforms"),
      path: "/settings/connected_platforms",
      active: (path) => path === "/settings/connected_platforms",
      groupId: "integrations"
    }
  ]

  return [...items, ...pluginItems]
}

function groupSettingsNavItems(items: SettingsNavigationItem[]) {
  const groups = SETTINGS_NAV_GROUPS.map((group) => ({ group, items: items.filter((item) => item.groupId === group.id) })).filter(
    ({ items }) => items.length > 0
  )
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
    return (
      <main aria-label={t("shell.spa_aria")} className="p-6 text-sm text-gray-600">
        {t("loading")}
      </main>
    )
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
          <p className="mt-2 font-mono text-sm text-text-secondary">{app?.revision}</p>
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
