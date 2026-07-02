import { useQuery } from "@tanstack/react-query"
import { useEffect, useState, type ReactNode } from "react"
import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { NoticeToast } from "../components/NoticeToast"
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
      {renderAppRoutes(initialBootstrap)}
      <Route path="*" element={<BootstrapShell initialBootstrap={initialBootstrap} />} />
    </Routes>
  )

  return <AppChromeV2 initialBootstrap={initialBootstrap}>{routes}</AppChromeV2>
}

function RootRoute({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  if (bootstrap.isPending) {
    return <main aria-label="Syrus" className="p-6 text-sm text-gray-600">Loading...</main>
  }

  if (bootstrap.isError) {
    return (
      <main aria-label="Syrus" className="p-6">
        <p className="text-sm text-red-700">Unable to load this Syrus instance.</p>
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
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const invitationToken = new URLSearchParams(location.search).get("token")?.trim()
  const cta = publicCta(payload.public, prefix, invitationToken)
  // No "Sign in" when sign-ups are locked, or when no users exist yet (the
  // first account is created via "Set up this Syrus instance" — there is
  // nobody to sign in as).
  const showSignIn = cta.kind !== "locked" && cta.kind !== "first"
  const signInPath = withRoutePrefix(payload.public.sign_in_path, prefix)
  const signupPath = invitationToken
    ? `${withRoutePrefix(payload.public.signup_path, prefix)}?token=${encodeURIComponent(invitationToken)}`
    : withRoutePrefix(payload.public.signup_path, prefix)
  const workflowSteps = [
    ["Issue", "A GitHub issue, PR comment, schedule, retry, or rebase enters the queue."],
    ["Job", "Syrus creates the thread, workspace, branch, prompt, logs, and state machine records."],
    ["Agent", "Claude or Codex runs in the cloned repository with bounded setup and captured output."],
    ["PR", "Syrus commits the result, captures the three-dot diff, and opens or updates the pull request."]
  ]
  const featureCards = [
    ["Polling, not webhooks", "Runs from outbound GitHub polling, so private deployments do not need inbound callback plumbing."],
    ["Operator-grade state", "Jobs, Workflows, Steps, and Runs keep retries, failures, feedback, summaries, and costs auditable."],
    ["Credentials stay local", "Use a GitHub App or PAT fallback while agent provider configuration remains under your instance control."],
    ["PR feedback loops", "Review comments, CI failures, retries, and rebases become follow-up attempts on the same Job."]
  ]

  return (
    <main aria-label="Syrus public landing" className="mx-auto max-w-[96rem] px-6 py-8 sm:py-12">
      <section className="grid gap-10 lg:grid-cols-[minmax(0,1fr)_32rem] lg:items-center">
        <div className="max-w-3xl">
          <p className="text-sm font-medium uppercase text-blue-700">Self-hosted agent workflow control</p>
          <h1 className="mt-4 max-w-2xl text-4xl font-semibold leading-tight text-gray-950 sm:text-5xl">
            Syrus turns GitHub issues into reviewed pull requests.
          </h1>
          <p className="mt-5 max-w-2xl text-lg leading-8 text-gray-700">
            Delegate work from GitHub and keep the deterministic parts in your hands: repository setup, credentials, queues, retries, rebases, summaries, and the PR that lands back in review.
          </p>
          <div className="mt-7 flex flex-col gap-3 sm:flex-row sm:items-center">
            <Link className={landingPrimaryButtonClass()} to={cta.href}>{cta.label}</Link>
            {showSignIn ? <Link className={landingSecondaryButtonClass()} to={signInPath}>Sign in</Link> : null}
          </div>
          <p className="mt-3 max-w-xl text-sm text-gray-600">{cta.description}</p>
        </div>

        <aside aria-label="Syrus run flow" className="rounded border border-gray-200 bg-white p-5 shadow-sm">
          <div className="flex items-center justify-between gap-3 border-b border-gray-100 pb-4">
            <div>
              <h2 className="text-base font-semibold text-gray-900">Live work path</h2>
              <p className="mt-1 text-sm text-gray-600">From external signal to pull request.</p>
            </div>
            <span className="rounded bg-green-100 px-2 py-1 text-xs font-medium text-green-800">Audited</span>
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
              <dt className="text-blue-800">Workspace</dt>
              <dd className="mt-1 font-semibold text-blue-950">Cloned</dd>
            </div>
            <div className="rounded bg-amber-50 p-2">
              <dt className="text-amber-800">Diff</dt>
              <dd className="mt-1 font-semibold text-amber-950">Captured</dd>
            </div>
            <div className="rounded bg-green-50 p-2">
              <dt className="text-green-800">PR</dt>
              <dd className="mt-1 font-semibold text-green-950">Updated</dd>
            </div>
          </dl>
        </aside>
      </section>

      <section className="mt-12" aria-label="Workflow">
        <div className="max-w-3xl">
          <p className="text-sm font-medium text-blue-700">Issue to PR</p>
          <h2 className="mt-2 text-2xl font-semibold text-gray-950">The agent writes code; Syrus owns the run.</h2>
          <p className="mt-3 text-sm leading-6 text-gray-600">Every attempt has a visible state, workspace, logs, prompt, provider, captured diff, and PR summary.</p>
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

      <section className="mt-12 grid gap-6 lg:grid-cols-[22rem_minmax(0,1fr)] lg:items-start" aria-label="Why self-host Syrus">
        <div>
          <p className="text-sm font-medium text-blue-700">Why self-host</p>
          <h2 className="mt-2 text-2xl font-semibold text-gray-950">Keep automation close to the repositories it changes.</h2>
          <p className="mt-3 text-sm leading-6 text-gray-600">
            Syrus is built for operators who want agent work to pass through their own queues, credentials, audit logs, and deployment boundaries before a pull request appears.
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

      <section className="mt-12 rounded border border-gray-200 bg-white p-5" aria-label="Instance access">
        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-center">
          <div>
            <p className="text-sm font-medium text-blue-700">This instance</p>
            <h2 className="mt-2 text-2xl font-semibold text-gray-950">{cta.label}</h2>
            <p className="mt-3 text-sm leading-6 text-gray-600">
              {cta.kind === "invite" ? "Use the invitation token in this URL to create your account on this instance." : cta.description}
            </p>
            {!payload.public.first_signup && !payload.public.signups_open && !invitationToken ? (
              <p className="mt-2 text-sm leading-6 text-gray-600">
                Access to this Syrus instance is controlled by its operator. Use an invitation link, or sign in with an existing account.
              </p>
            ) : null}
            <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center">
              <Link aria-label={`${cta.label} from instance access`} className={landingPrimaryButtonClass()} to={cta.href}>{cta.label}</Link>
              {showSignIn ? <Link className={landingSecondaryButtonClass()} to={signInPath}>Sign in</Link> : null}
            </div>
          </div>
          <dl className="grid gap-3 text-sm sm:grid-cols-3 lg:grid-cols-1">
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">First admin</dt>
              <dd className="font-medium text-gray-900">{payload.public.first_signup ? "Ready to create" : "Already configured"}</dd>
            </div>
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">Sign-ups</dt>
              <dd className="font-medium text-gray-900">{payload.public.signups_open ? "Open" : "Invitation-only"}</dd>
            </div>
            <div className="flex items-start justify-between gap-4 rounded bg-gray-50 px-3 py-2">
              <dt className="text-gray-600">Invitation link</dt>
              <dd className="font-medium text-gray-900">{invitationToken ? "Detected" : "Not present"}</dd>
            </div>
          </dl>
        </div>
      </section>

      <section className="mt-10 flex flex-col gap-3 border-t border-gray-200 pt-6 text-sm text-gray-700 sm:flex-row sm:items-center">
        <a className="font-medium text-blue-700 underline hover:no-underline" href={payload.public.docs_url}>Read the setup docs</a>
        <span className="hidden text-gray-300 sm:inline">/</span>
        <a className="font-medium text-blue-700 underline hover:no-underline" href={payload.public.evaluation_url}>Run Syrus locally</a>
        {payload.public.signups_open || invitationToken ? (
          <>
            <span className="hidden text-gray-300 sm:inline">/</span>
            <Link className="font-medium text-blue-700 underline hover:no-underline" to={signupPath}>Create account</Link>
          </>
        ) : null}
      </section>
    </main>
  )
}

function publicCta(publicState: BootstrapPayload["public"], prefix: string, invitationToken?: string) {
  if (publicState.first_signup) {
    return {
      kind: "first" as const,
      href: withRoutePrefix(publicState.signup_path, prefix),
      label: "Set up this Syrus instance",
      description: "No users exist yet. The first account becomes the administrator for this instance."
    }
  }

  if (invitationToken) {
    return {
      kind: "invite" as const,
      href: `${withRoutePrefix(publicState.signup_path, prefix)}?token=${encodeURIComponent(invitationToken)}`,
      label: "Create account from invitation",
      description: "An invitation token is present in this link. Create your account to join this instance."
    }
  }

  if (publicState.signups_open) {
    return {
      kind: "open" as const,
      href: withRoutePrefix(publicState.signup_path, prefix),
      label: "Create account",
      description: "Open sign-ups are enabled for this instance."
    }
  }

  return {
    kind: "locked" as const,
    href: withRoutePrefix(publicState.sign_in_path, prefix),
    label: "Sign in",
    description: "This instance is invitation-only. Ask the operator for an invitation if you need access."
  }
}

function renderAppRoutes(initialBootstrap: BootstrapPayload | null) {
  return appRouteDefinitions.flatMap(({ path, element }) => [
    <Route element={element} key={path} path={path} />,
    <Route element={element} key={`/app-shell${path}`} path={`/app-shell${path}`} />
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
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)

  return (
    <div className="flex min-h-full flex-col bg-gray-50 dark:bg-gray-900 lg:flex-row">
      <aside className="shrink-0 border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950 lg:w-56 lg:border-b-0 lg:border-r">
        <nav aria-label="Settings navigation" className="flex gap-2 overflow-x-auto px-4 py-3 text-sm lg:flex-col lg:gap-1 lg:overflow-visible lg:p-4">
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
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })

  if (bootstrap.isPending) {
    return <main aria-label="Syrus SPA" className="p-6 text-sm text-gray-600">Loading...</main>
  }

  if (bootstrap.isError) {
    return (
      <main aria-label="Syrus SPA" className="p-6">
        <p className="text-sm text-red-700">Unable to load the app shell.</p>
      </main>
    )
  }

  const { current_user: user, app } = bootstrap.data

  return (
    <main aria-label="Syrus SPA" className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500">React shell</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900">Syrus</h1>
      </header>

      <section className="grid gap-4 sm:grid-cols-2">
        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">Signed in</h2>
          <p className="mt-2 text-sm text-gray-700">{user?.display_name || "Not signed in"}</p>
          {user ? <p className="text-xs text-gray-500">{user.email_address}</p> : null}
        </div>

        <div className="rounded border border-gray-200 bg-white p-4">
          <h2 className="text-sm font-medium text-gray-900">Revision</h2>
          <p className="mt-2 font-mono text-sm text-gray-700">{app.revision}</p>
          {app.revision_url ? (
            <a className="text-xs text-blue-600 underline hover:no-underline" href={app.revision_url}>
              View commit
            </a>
          ) : null}
        </div>
      </section>
    </main>
  )
}

function landingPrimaryButtonClass() {
  return "inline-flex items-center justify-center rounded bg-blue-700 px-4 py-2.5 text-sm font-semibold text-white hover:bg-blue-600"
}

function landingSecondaryButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-4 py-2.5 text-sm font-semibold text-gray-800 hover:bg-gray-50"
}

function settingsSideNavLinkClass(active: boolean) {
  return `whitespace-nowrap rounded px-3 py-2 font-medium ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}
