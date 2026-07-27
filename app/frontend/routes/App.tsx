import { withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { BRAND_ICON_SRC } from "../lib/brandIcon"
import { useEffect, useState, type ReactNode } from "react"
import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { authPrimaryButtonClass } from "../lib/buttonStyles"
import { isDesktopShell } from "../lib/desktopShell"
import { useT } from "../hooks/useT"
import { NoticeToast } from "../components/NoticeToast"
import { RouteErrorBoundary } from "../components/RouteErrorBoundary"
import { NotificationsRoute } from "../components/Notifications"
import { useAppEvents } from "../lib/useAppEvents"
import { AdminConsole } from "./AdminConsole"
import { AppChromeV2 } from "./AppChromeV2"
import { AdminGithubAppConfirm, AdminGithubAppRegister } from "./AdminGithubApp"
import { AdminInvitations } from "./AdminInvitations"
import { AdminInstallations } from "./AdminInstallations"
import { AdminOverview } from "./AdminOverview"
import { AdminQueueRoute } from "./AdminQueue"
import { AdminProcessDetail, AdminProcessesIndex } from "./AdminProcesses"
import { AdminSettings } from "./AdminSettings"
import { AdminStuck } from "./AdminStuck"
import { AdminTranscript } from "./AdminTranscript"
import { AdminUserDetailRoute, AdminUsersIndex } from "./AdminUsers"
import { AgentSettingsRoute } from "./AgentSettings"
import { PasswordRequestRoute, PasswordResetRoute, SignInRoute, SignUpRoute } from "./Auth"
import { ChatSearchRoute } from "./ChatSearch"
import { ChatRoute, SharedChatRoute } from "./Chat"
import { CredentialsRoute } from "./Credentials"
import { CronTemplateDetailRoute, CronTemplateFormRoute, CronTemplatesIndex } from "./CronTemplates"
import { DashboardRoute } from "./Dashboard"
import { DirectJobNewRoute } from "./DirectJobNew"
import { AdminFeatures } from "./AdminFeatures"
import { EpicDetailRoute } from "./EpicDetail"
import { EpicFormRoute } from "./EpicForm"
import { HiddenChatsRoute } from "./HiddenChats"
import { JobDetailRoute } from "./JobDetail"
import { MemoriesRoute } from "./Memories"
import { NotificationsSettingsRoute } from "./NotificationsSettings"
import { OnboardingRoute } from "./Onboarding"
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import { AccountProfileRoute, ProfileRoute } from "./Profile"
import { PreferencesRoute } from "./Preferences"
import { RepositoriesIndex } from "./Repositories"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import { RepositoryDocumentsRoute } from "./RepositoryDocuments"
import { RepositoryFormRoute } from "./RepositoryForm"
import { RepositoryScheduledTasksRoute } from "./RepositoryScheduledTasks"
import { ScheduledTaskDetailRoute, ScheduledTaskFormRoute, ScheduledTasksIndex } from "./ScheduledTasks"
import { SearchRoute } from "./Search"
import { SpendingInsightsRoute } from "./SpendingInsights"
import { RepositoryInsightsRoute } from "./RepositoryInsights"
import { AdminInsightsRoute } from "./AdminInsights"
import { Tags } from "./Tags"
import { TerminalRoute } from "./Terminal"
import { TeamDirectoryRoute, TeamProfileRoute } from "./Profiles"

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
  { path: "/search", element: <SearchRoute /> },
  { path: "/insights/spending", element: <SpendingInsightsRoute /> },
  { path: "/terminal", element: <TerminalRoute /> },
  { path: "/notifications", element: <NotificationsRoute /> },
  { path: "/setup", element: <SetupRedirect /> },
  { path: "/admin", element: <AdminOverview /> },
  { path: "/admin/queue", element: <AdminQueueRoute /> },
  { path: "/admin/queue/:tab", element: <AdminQueueRoute /> },
  { path: "/admin/stuck", element: <AdminStuck /> },
  { path: "/admin/processes", element: <AdminProcessesIndex /> },
  { path: "/admin/processes/:id", element: <AdminProcessDetail /> },
  { path: "/admin/runs/:runId/transcript", element: <AdminTranscript /> },
  { path: "/admin/users", element: <AdminUsersIndex /> },
  { path: "/admin/users/:id", element: <AdminUserDetailRoute /> },
  { path: "/admin/console", element: <AdminConsole /> },
  { path: "/admin/installations", element: <AdminInstallations /> },
  { path: "/admin/github_app/register", element: <AdminGithubAppRegister /> },
  { path: "/admin/github_app/confirm", element: <AdminGithubAppConfirm /> },
  { path: "/admin/features", element: <AdminFeatures /> },
  { path: "/admin/insights", element: <AdminInsightsRoute /> },
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
  { path: "/profiles", element: <TeamDirectoryRoute /> },
  { path: "/profiles/:id", element: <TeamProfileRoute /> },
  { path: "/documents", element: <SettingsSectionRoute><PersonalDocumentsRoute /></SettingsSectionRoute> },
  { path: "/memories", element: <SettingsSectionRoute><MemoriesRoute /></SettingsSectionRoute> },
  { path: "/profiles/:id", element: <ProfileRoute /> },
  { path: "/tags", element: <SettingsSectionRoute><Tags /></SettingsSectionRoute> },
  { path: "/cron_templates", element: <SettingsSectionRoute><CronTemplatesIndex /></SettingsSectionRoute> },
  { path: "/cron_templates/new", element: <SettingsSectionRoute><CronTemplateFormRoute mode="new" /></SettingsSectionRoute> },
  { path: "/cron_templates/:id", element: <SettingsSectionRoute><CronTemplateDetailRoute /></SettingsSectionRoute> },
  { path: "/cron_templates/:id/edit", element: <SettingsSectionRoute><CronTemplateFormRoute mode="edit" /></SettingsSectionRoute> },
  { path: "/scheduled_tasks", element: <ScheduledTasksIndex /> },
  { path: "/scheduled_tasks/:id", element: <ScheduledTaskDetailRoute /> },
  { path: "/scheduled_tasks/:id/edit", element: <ScheduledTaskFormRoute mode="edit" /> },
  { path: "/repositories/:repositoryId/scheduled_tasks", element: <RepositoryScheduledTasksRoute /> },
  { path: "/repositories/:repositoryId/scheduled_tasks/new", element: <ScheduledTaskFormRoute mode="new" /> },
  { path: "/repositories/:repositoryId/documents", element: <RepositoryDocumentsRoute /> },
  { path: "/repositories/new", element: <RepositoryFormRoute mode="new" /> },
  { path: "/repositories/:id/edit", element: <RepositoryFormRoute mode="edit" /> },
  { path: "/repositories/:id/insights", element: <RepositoryInsightsRoute /> },
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
  const { isDisconnected, justReconnected, clearReconnected } = useAppEvents()
  const initialBootstrap = readInitialBootstrap()

  const [bannerDismissed, setBannerDismissed] = useState(false)
  useEffect(() => {
    if (isDisconnected) setBannerDismissed(false)
  }, [isDisconnected])

  return (
    <>
      <AppShell initialBootstrap={initialBootstrap} />
      {isDisconnected && !bannerDismissed ? (
        <NoticeToast persistent onDismiss={() => setBannerDismissed(true)}>
          <span className="flex items-center gap-1.5">
            <span aria-hidden="true" className="inline-block h-2 w-2 shrink-0 rounded-full bg-amber-500" />
            Connection lost — updates paused
          </span>
        </NoticeToast>
      ) : null}
      {justReconnected ? (
        <NoticeToast onDismiss={clearReconnected} message="Reconnected — data refreshed" />
      ) : null}
    </>
  )
}

function AppShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const routes = (
    <Routes>
      <Route path="/" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      <Route path="/app-shell" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      {renderAppRoutes(initialBootstrap)}
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
  const signupPath = invitationToken
    ? `${withRoutePrefix(payload.public.signup_path, prefix)}?token=${encodeURIComponent(invitationToken)}`
    : withRoutePrefix(payload.public.signup_path, prefix)

  // Inside the desktop shell the app is already installed and pointed at an
  // instance, so a merely signed-out user should land on sign-in (or the
  // invite/open signup page — on open-signup instances the landing was the
  // only path to signup, and SignUp links back to sign-in), never the
  // self-hosting marketing pitch. First run keeps the welcome below — it
  // doubles as the desktop first-run screen.
  if (isDesktopShell() && cta.kind !== "first") {
    return <Navigate replace to={cta.kind === "invite" || cta.kind === "open" ? cta.href : signInPath} />
  }

  // First run (no users yet) gets a minimal welcome, not the marketing pitch:
  // whoever sees this screen has already installed the instance — most often
  // inside the desktop app — and just needs the one next step.
  if (cta.kind === "first") {
    return (
      <main aria-label={t("aria_first_run")} className="flex min-h-[70vh] items-center justify-center px-6">
        <div className="max-w-md text-center">
          <img alt="" aria-hidden="true" className="mx-auto h-16 w-16 rounded-2xl" src={BRAND_ICON_SRC} />
          <h1 className="mt-6 text-3xl font-semibold text-gray-950 dark:text-gray-100">{t("welcome")}</h1>
          <p className="mt-3 text-sm leading-6 text-gray-600 dark:text-gray-400">{cta.description}</p>
          <div className="mt-7">
            <Link className={authPrimaryButtonClass} to={cta.href}>{cta.label}</Link>
          </div>
        </div>
      </main>
    )
  }

  const workflowSteps = [
    [t("step_issue_title"), t("step_issue_body")],
    [t("step_job_title"), t("step_job_body")],
    [t("step_agent_title"), t("step_agent_body")],
    [t("step_pr_title"), t("step_pr_body")]
  ]
  const featureCards = [
    [t("feature1_title"), t("feature1_body")],
    [t("feature2_title"), t("feature2_body")],
    [t("feature3_title"), t("feature3_body")],
    [t("feature4_title"), t("feature4_body")]
  ]

  return (
    <main aria-label={t("aria_public")} className="mx-auto max-w-[96rem] px-6 py-8 sm:py-12">
      <section className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_32rem] lg:items-center">
        <div className="max-w-3xl">
          <p className="text-sm font-medium uppercase text-blue-700">{t("eyebrow_hero")}</p>
          <h1 className="mt-4 max-w-2xl text-4xl font-semibold leading-tight text-gray-950 sm:text-5xl">
            {t("hero_title")}
          </h1>
          <p className="mt-5 max-w-2xl text-lg leading-8 text-gray-700">
            {t("hero_body")}
          </p>
          <div className="mt-7 flex flex-col gap-3 sm:flex-row sm:items-center">
            <Link className={authPrimaryButtonClass} to={cta.href}>{cta.label}</Link>
            {showSignIn ? <Link className={landingSecondaryButtonClass()} to={signInPath}>{t("sign_in")}</Link> : null}
          </div>
          <p className="mt-3 max-w-xl text-sm text-gray-600">{cta.description}</p>
        </div>

        <aside aria-label={t("aria_run_flow")} className="rounded border border-gray-200 bg-white p-5 shadow-sm">
          <div className="flex items-center justify-between gap-3 border-b border-gray-100 pb-4">
            <div>
              <h2 className="text-base font-semibold text-gray-900">{t("live_work_path")}</h2>
              <p className="mt-1 text-sm text-gray-600">{t("live_work_sub")}</p>
            </div>
            <span className="rounded bg-green-100 px-2 py-1 text-xs font-medium text-green-800">{t("audited")}</span>
          </div>
          <ol className="mt-5 space-y-3">
            {workflowSteps.map(([title, body], index) => (
              <li className="grid grid-cols-[2.25rem_minmax(0,1fr)] gap-3" key={title}>
                <div className="flex h-9 w-9 items-center justify-center rounded bg-gray-900 text-sm font-semibold text-white">{index + 1}</div>
                <div>
                  <h3 className="text-sm font-semibold text-gray-900">{title}</h3>
                  <p className="mt-1 text-sm leading-6 text-gray-600">{body}</p>
                </div>
              </li>
            ))}
          </ol>
          <dl className="mt-5 grid grid-cols-3 gap-2 border-t border-gray-100 pt-4 text-center text-xs">
            <div className="rounded bg-blue-50 p-2">
              <dt className="text-blue-800">{t("workspace")}</dt>
              <dd className="mt-1 font-semibold text-blue-950">{t("cloned")}</dd>
            </div>
            <div className="rounded bg-amber-50 p-2">
              <dt className="text-amber-800">{t("diff")}</dt>
              <dd className="mt-1 font-semibold text-amber-950">{t("captured")}</dd>
            </div>
            <div className="rounded bg-green-50 p-2">
              <dt className="text-green-800">{t("pr")}</dt>
              <dd className="mt-1 font-semibold text-green-950">{t("updated")}</dd>
            </div>
          </dl>
        </aside>
      </section>

      <section className="mt-12" aria-label={t("aria_workflow")}>
        <div className="max-w-3xl">
          <p className="text-sm font-medium text-blue-700">{t("eyebrow_workflow")}</p>
          <h2 className="mt-2 text-2xl font-semibold text-gray-950">{t("workflow_title")}</h2>
          <p className="mt-3 text-sm leading-6 text-gray-600">{t("workflow_body")}</p>
        </div>
        <div className="mt-5 grid gap-4 md:grid-cols-4">
          {workflowSteps.map(([title, body], index) => (
          <article className="rounded border border-gray-200 bg-white p-4" key={title}>
            <div className="flex h-8 w-8 items-center justify-center rounded bg-gray-900 text-sm font-semibold text-white">{index + 1}</div>
            <h2 className="mt-4 text-base font-semibold text-gray-900">{title}</h2>
            <p className="mt-2 text-sm leading-6 text-gray-600">{body}</p>
          </article>
          ))}
        </div>
      </section>

      <section className="mt-12 grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)] lg:items-start" aria-label={t("aria_why")}>
        <div>
          <p className="text-sm font-medium text-blue-700">{t("eyebrow_why")}</p>
          <h2 className="mt-2 text-2xl font-semibold text-gray-950">{t("why_title")}</h2>
          <p className="mt-3 text-sm leading-6 text-gray-600">
            {t("why_body")}
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          {featureCards.map(([title, body]) => (
            <article className="rounded border border-gray-200 bg-white p-4" key={title}>
              <h3 className="text-base font-semibold text-gray-900">{title}</h3>
              <p className="mt-2 text-sm leading-6 text-gray-600">{body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="mt-12 rounded border border-gray-200 bg-white p-5" aria-label={t("aria_instance_access")}>
        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-center">
          <div>
            <p className="text-sm font-medium text-blue-700">{t("eyebrow_instance")}</p>
            <h2 className="mt-2 text-2xl font-semibold text-gray-950">{cta.label}</h2>
            <p className="mt-3 text-sm leading-6 text-gray-600">
              {cta.kind === "invite" ? t("invite_token_hint") : cta.description}
            </p>
            {!payload.public.first_signup && !payload.public.signups_open && !invitationToken ? (
              <p className="mt-2 text-sm leading-6 text-gray-600">
                {t("access_controlled")}
              </p>
            ) : null}
            <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center">
              <Link aria-label={t("from_instance_access", { label: cta.label })} className={authPrimaryButtonClass} to={cta.href}>{cta.label}</Link>
              {showSignIn ? <Link className={landingSecondaryButtonClass()} to={signInPath}>{t("sign_in")}</Link> : null}
            </div>
          </div>
          <dl className="grid gap-3 text-sm sm:grid-cols-3 lg:grid-cols-1">
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">{t("first_admin")}</dt>
              <dd className="font-medium text-gray-900">{payload.public.first_signup ? t("ready_to_create") : t("already_configured")}</dd>
            </div>
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">{t("signups")}</dt>
              <dd className="font-medium text-gray-900">{payload.public.signups_open ? t("open") : t("invitation_only")}</dd>
            </div>
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">{t("invitation_link")}</dt>
              <dd className="font-medium text-gray-900">{invitationToken ? t("detected") : t("not_present")}</dd>
            </div>
          </dl>
        </div>
      </section>

      <section className="mt-10 flex flex-col gap-3 border-t border-gray-200 pt-6 text-sm text-gray-700 sm:flex-row sm:items-center">
        <a className="font-medium text-blue-700 underline hover:no-underline" href={payload.public.docs_url}>{t("read_docs")}</a>
        <span className="hidden text-gray-300 sm:inline">/</span>
        <a className="font-medium text-blue-700 underline hover:no-underline" href={payload.public.evaluation_url}>{t("run_locally")}</a>
        {payload.public.signups_open || invitationToken ? (
          <>
            <span className="hidden text-gray-300 sm:inline">/</span>
            <Link className="font-medium text-blue-700 underline hover:no-underline" to={signupPath}>{t("create_account")}</Link>
          </>
        ) : null}
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
    <Route element={<RouteErrorBoundary key={path}>{element}</RouteErrorBoundary>} key={path} path={path} />,
    <Route element={<RouteErrorBoundary key={`/app-shell${path}`}>{element}</RouteErrorBoundary>} key={`/app-shell${path}`} path={`/app-shell${path}`} />
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

function OnboardingShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  return <OnboardingRoute bootstrap={bootstrap.data ?? initialBootstrap} />
}

function SettingsSectionRoute({ children }: { children: ReactNode }) {
  const { t } = useT("common")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)

  return (
    <div className="flex min-h-full flex-col bg-gray-50 dark:bg-gray-900 lg:flex-row">
      <aside className="shrink-0 border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950 lg:w-56 lg:border-b-0 lg:border-r">
        <nav aria-label={t("shell.settings_nav_aria")} className="flex gap-2 overflow-x-auto px-4 py-3 text-sm lg:flex-col lg:gap-1 lg:overflow-visible lg:p-4">
          {settingsNavigationItems().map((item) => (
            <Link className={settingsSideNavLinkClass(item.active(normalizedPath))} key={item.label} to={withRoutePrefix(item.path, prefix)}>
              {item.label}
            </Link>
          ))}
        </nav>
      </aside>
      <div className="min-w-0 flex-1">
        {children}
      </div>
    </div>
  )
}

function settingsNavigationItems(): Array<{ label: string; path: string; active: (path: string) => boolean }> {
  return [
    { label: "Profile", path: "/profile", active: (path) => path === "/settings" || path === "/profile" },
    { label: "Credentials", path: "/credentials", active: (path) => path === "/credentials" || path === "/credentials/edit" },
    { label: "Agent Settings", path: "/settings/agent", active: (path) => path === "/settings/agent" },
    { label: "Preferences", path: "/settings/preferences", active: (path) => path === "/settings/preferences" },
    { label: "Notifications", path: "/notifications/settings", active: (path) => path === "/notifications/settings" },
    { label: "Hidden chats", path: "/settings/hidden_chats", active: (path) => path === "/settings/hidden_chats" },
    { label: "Documents", path: "/documents", active: (path) => path === "/documents" },
    { label: "Memories", path: "/memories", active: (path) => path === "/memories" },
    { label: "Templates", path: "/cron_templates", active: (path) => path.startsWith("/cron_templates") },
    { label: "Tags", path: "/tags", active: (path) => path === "/tags" }
  ]
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

  const { current_user: user, app } = bootstrap.data

  return (
    <main aria-label={t("shell.spa_aria")} className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500">{t("shell.react_shell")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900">{t("app_name")}</h1>
      </header>

      <section className="grid gap-4 sm:grid-cols-2">
        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">{t("shell.signed_in")}</h2>
          <p className="mt-2 text-sm text-gray-700">{user?.display_name || t("shell.not_signed_in")}</p>
          {user ? <p className="text-xs text-gray-500">{user.email_address}</p> : null}
        </div>

        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">{t("shell.revision")}</h2>
          <p className="mt-2 font-mono text-sm text-gray-700">{app.revision}</p>
          {app.revision_url ? (
            <a className="text-xs text-blue-600 underline hover:no-underline" href={app.revision_url}>
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
  return `whitespace-nowrap rounded px-3 py-2 font-medium ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

