import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState, type ReactNode } from "react"
import { Link, Navigate, Route, Routes, useLocation } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { patchJson } from "../api/client"
import { BugReportButton } from "../components/BugReportButton"
import { NoticeToast } from "../components/NoticeToast"
import { SyrusBrand } from "../components/SyrusBrand"
import { LayoutVersionProvider } from "../lib/layoutVersion"
import { useAppEvents } from "../lib/useAppEvents"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
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
import { PasswordRequestRoute, PasswordResetRoute, SignInRoute, SignUpRoute } from "./Auth"
import { ChatNewRoute } from "./ChatNew"
import { ChatRoute } from "./Chat"
import { CredentialsRoute } from "./Credentials"
import { CronTemplateDetailRoute, CronTemplateFormRoute, CronTemplatesIndex } from "./CronTemplates"
import { DashboardRoute } from "./Dashboard"
import { DirectJobNewRoute } from "./DirectJobNew"
import { EpicDetailRoute } from "./EpicDetail"
import { EpicFormRoute } from "./EpicForm"
import { JobDetailRoute } from "./JobDetail"
import { OnboardingRoute } from "./Onboarding"
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import { ProfileRoute } from "./Profile"
import { RepositoriesIndex } from "./Repositories"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import { RepositoryDocumentsRoute } from "./RepositoryDocuments"
import { RepositoryFormRoute } from "./RepositoryForm"
import { RepositoryScheduledTasksRoute } from "./RepositoryScheduledTasks"
import { ScheduledTaskDetailRoute, ScheduledTaskFormRoute, ScheduledTasksIndex } from "./ScheduledTasks"
import { SmartFolders } from "./SmartFolders"
import { SpendingInsightsRoute } from "./SpendingInsights"
import { Tags } from "./Tags"
import { TeamDirectoryRoute, TeamProfileRoute } from "./Profiles"

type AppRouteDefinition = {
  path: string
  element: ReactNode
}

const PUBLILIUS_SYRUS_WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Publilius_Syrus"
const PUBLILIUS_SYRUS_QUOTES = [
  "A rolling stone gathers no moss.",
  "A good reputation is more valuable than money.",
  "It is a bad plan that admits of no modification.",
  "No one knows what he can do until he tries.",
  "Practice is the best of all instructors.",
  "The fear of death is more to be dreaded than death itself.",
  "Where there is unity there is always victory."
]

const appRouteDefinitions: AppRouteDefinition[] = [
  { path: "/session/new", element: <SignInRoute /> },
  { path: "/users/new", element: <SignUpRoute /> },
  { path: "/passwords/new", element: <PasswordRequestRoute /> },
  { path: "/passwords/:token/edit", element: <PasswordResetRoute /> },
  { path: "/dashboard", element: <DashboardRoute /> },
  { path: "/dashboard/epics", element: <DashboardRoute /> },
  { path: "/dashboard/jobs", element: <DashboardRoute /> },
  { path: "/dashboard/workflows", element: <DashboardRoute /> },
  { path: "/insights/spending", element: <SpendingInsightsRoute /> },
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
  { path: "/invitations", element: <AdminInvitations /> },
  { path: "/settings/edit", element: <AdminSettings /> },
  { path: "/settings", element: <CredentialsRoute /> },
  { path: "/credentials/edit", element: <CredentialsRoute /> },
  { path: "/profiles", element: <TeamDirectoryRoute /> },
  { path: "/profiles/:id", element: <TeamProfileRoute /> },
  { path: "/documents", element: <PersonalDocumentsRoute /> },
  { path: "/profiles/:id", element: <ProfileRoute /> },
  { path: "/smart_folders", element: <SmartFolders /> },
  { path: "/tags", element: <Tags /> },
  { path: "/cron_templates", element: <CronTemplatesIndex /> },
  { path: "/cron_templates/new", element: <CronTemplateFormRoute mode="new" /> },
  { path: "/cron_templates/:id", element: <CronTemplateDetailRoute /> },
  { path: "/cron_templates/:id/edit", element: <CronTemplateFormRoute mode="edit" /> },
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
  { path: "/jobs/new", element: <DirectJobNewRoute /> },
  { path: "/jobs/:id/source", element: <JobDetailRoute /> },
  { path: "/jobs/:id", element: <JobDetailRoute /> },
  { path: "/epics/new", element: <EpicFormRoute mode="new" /> },
  { path: "/epics/:id/edit", element: <EpicFormRoute mode="edit" /> },
  { path: "/epics/:id", element: <EpicDetailRoute /> },
  { path: "/chats/new", element: <ChatNewRoute /> },
  { path: "/chats/:id", element: <ChatRoute /> }
]

export function App() {
  useAppEvents()
  const initialBootstrap = readInitialBootstrap()

  return <AppShell initialBootstrap={initialBootstrap} />
}

function AppShell({ initialBootstrap }: { initialBootstrap: BootstrapPayload | null }) {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: initialBootstrap != null,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const data = bootstrap.data ?? initialBootstrap
  const layoutVersion = data?.current_user?.layout_version ?? "v1"
  const routes = (
    <Routes>
      <Route path="/" element={<RootRoute initialBootstrap={initialBootstrap} />} />
      {renderAppRoutes(initialBootstrap)}
      <Route path="*" element={<BootstrapShell initialBootstrap={initialBootstrap} />} />
    </Routes>
  )

  return (
    <LayoutVersionProvider value={layoutVersion}>
      {layoutVersion === "v2" ? (
        <AppChromeV2 initialBootstrap={initialBootstrap}>{routes}</AppChromeV2>
      ) : (
        <AppChrome initialBootstrap={initialBootstrap}>
          {routes}
        </AppChrome>
      )}
    </LayoutVersionProvider>
  )
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
        <a className="font-medium text-blue-700 underline hover:no-underline" href={payload.public.evaluation_url}>Evaluate Syrus for a repository</a>
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

function AppChrome({ children, initialBootstrap }: { children: ReactNode; initialBootstrap: BootstrapPayload | null }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)
  const shouldLoadChromeBootstrap = initialBootstrap != null
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: shouldLoadChromeBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const data = bootstrap.data ?? initialBootstrap
  const user = data?.current_user
  const app = data?.app
  const defaultChatPath = withRoutePrefix(data?.navigation?.default_chat_path || "/chats/new", prefix)
  const quote = useMemo(randomPubliliusSyrusQuote, [])

  // Onboarding gates the chrome: before the operator starts the onboarding
  // chat, every tab except Setup is hidden and the brand returns to
  // onboarding. Starting the chat reveals the tabs and points the brand at
  // the chat. The Setup tab stays until the first Epic lands.
  const inOnboarding = !!data?.setup && !data.setup.complete
  const onboardingChatStarted = !!data?.setup?.chat_started
  const tabsHidden = inOnboarding && !onboardingChatStarted
  const onboardingChatPath = data?.setup?.onboarding_chat_path ? withRoutePrefix(data.setup.onboarding_chat_path, prefix) : null
  const brandTo = inOnboarding
    ? (onboardingChatStarted && onboardingChatPath ? onboardingChatPath : `${prefix}/onboarding`)
    : defaultChatPath

  const navItems: Array<{ label: string; to: string; active: boolean; desktopOnly?: boolean }> = user ? [
    ...(inOnboarding ? [{ label: "Setup", to: `${prefix}/onboarding`, active: normalizedPath === "/onboarding" }] : []),
    ...(tabsHidden ? [] : [
      { label: "Dashboard", to: `${prefix}/dashboard/jobs?view=list`, active: normalizedPath === "/" || normalizedPath.startsWith("/dashboard") },
      { label: "Spending", to: `${prefix}/insights/spending`, active: normalizedPath.startsWith("/insights/spending"), desktopOnly: true },
      { label: "Repos", to: `${prefix}/repositories`, active: normalizedPath.startsWith("/repositories") },
      ...(data && data.team_user_count > 1 ? [ { label: "Team", to: `${prefix}/profiles`, active: normalizedPath.startsWith("/profiles"), desktopOnly: true } ] : []),
      { label: "Schedules", to: `${prefix}/scheduled_tasks`, active: normalizedPath === "/scheduled_tasks" || normalizedPath.startsWith("/scheduled_tasks/"), desktopOnly: true }
    ])
  ] : []

  return (
    <div className="min-h-screen bg-gray-50 text-gray-900 dark:bg-gray-900 dark:text-white">
      <header className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
        <div className="mx-auto flex max-w-[96rem] items-center justify-between gap-3 px-6 py-3">
          <div className="flex min-w-0 items-center gap-5">
            <Link className="text-lg font-semibold text-gray-900 dark:text-white" to={brandTo}><SyrusBrand /></Link>
            <nav aria-label="Primary" className="flex flex-nowrap gap-1 text-sm">
              {navItems.map((item) => (
                <Link className={`${item.desktopOnly ? "hidden sm:inline-flex" : ""} ${navLinkClass(item.active)}`} key={item.label} to={item.to}>{item.label}</Link>
              ))}
            </nav>
          </div>
          <div className="flex shrink-0 items-center justify-end gap-2 text-xs text-gray-500 dark:text-gray-400">
            {user ? (
              <>
                <AccountNavigation csrfToken={data?.csrf_token} prefix={prefix} showTeamProfile={(data?.team_user_count || 0) > 1} user={user} />
                {app ? <RevisionLink app={app} /> : null}
              </>
            ) : null}
          </div>
        </div>
      </header>
      {showsAdminNavigation(normalizedPath) ? <AdminNavigation normalizedPath={normalizedPath} prefix={prefix} /> : null}
      {showsSettingsNavigation(normalizedPath) ? <SettingsNavigation normalizedPath={normalizedPath} prefix={prefix} /> : null}
      <SystemAlertsBanner alerts={data?.system_alerts} prefix={prefix} />
      <FlashBanner flash={data?.flash} />
      {redirectsToSetup(data, normalizedPath) ? <Navigate replace to={`${prefix}/onboarding`} /> : children}
      {showsPubliliusSyrusFooter(normalizedPath) ? <PubliliusSyrusFooter quote={quote} /> : null}
      {user ? <BugReportButton context={bugReportContext(location.pathname)} /> : null}
    </div>
  )
}

function RevisionLink({ app }: { app: BootstrapPayload["app"] }) {
  const className = "hidden font-mono hover:text-blue-600 hover:underline dark:hover:text-blue-300 sm:inline"
  if (!app.revision_url) return <span className="hidden font-mono dark:text-gray-400 sm:inline">{app.revision}</span>

  return (
    <a className={className} href={app.revision_url}>
      {app.revision}
    </a>
  )
}

function PubliliusSyrusFooter({ quote }: { quote: string }) {
  return (
    <footer className="mx-auto hidden max-w-[96rem] px-6 py-8 text-center text-xs text-gray-500 dark:text-gray-400 lg:block">
      <a className="hover:text-blue-600 hover:underline dark:hover:text-blue-300" href={PUBLILIUS_SYRUS_WIKIPEDIA_URL} rel="noopener" target="_blank">
        {quote}
      </a>
    </footer>
  )
}

function AccountNavigation({ csrfToken, prefix, showTeamProfile, user }: { csrfToken?: string; prefix: string; showTeamProfile: boolean; user: NonNullable<BootstrapPayload["current_user"]> }) {
  const queryClient = useQueryClient()
  const [open, setOpen] = useState(false)
  const [theme, setTheme] = useState(user.theme)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  useEffect(() => {
    setTheme(user.theme)
    document.documentElement.classList.toggle("dark", user.theme === "dark")
  }, [user.theme])

  function toggleTheme() {
    const nextTheme = theme === "dark" ? "light" : "dark"
    document.documentElement.classList.toggle("dark", nextTheme === "dark")
    setTheme(nextTheme)
    void patchJson<{ theme: "light" | "dark" }>("/api/v1/app/theme", { theme: nextTheme }).then((payload) => {
      document.documentElement.classList.toggle("dark", payload.theme === "dark")
      setTheme(payload.theme)
    }).catch(() => {
      document.documentElement.classList.toggle("dark", theme === "dark")
      setTheme(theme)
    })
  }

  function switchToNewUi() {
    void patchJson<{ layout_version: "v1" | "v2" }>("/api/v1/app/layout_version", { layout_version: "v2" }).then((payload) => {
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapLayoutVersion(current, payload.layout_version))
      setOpen(false)
    })
  }

  return (
    <nav aria-label="Account" className="flex items-center gap-2">
      {user.admin ? <Link className={accountLinkClass()} to={`${prefix}/admin`}>admin</Link> : null}
      <button
        aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
        className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-700 hover:bg-gray-100 hover:text-blue-600 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"
        onClick={toggleTheme}
        title={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
        type="button"
      >
        {theme === "dark" ? <SunIcon /> : <MoonIcon />}
      </button>
      <Link aria-label="Account settings" className="inline-flex h-8 w-8 items-center justify-center text-gray-700 hover:text-blue-600 dark:text-gray-300 dark:hover:text-blue-300 sm:hidden" to={`${prefix}/settings`}>
        <UserIcon />
      </Link>
      <div className="relative hidden sm:block" ref={menuRef}>
        <button
          aria-expanded={open}
          aria-haspopup="menu"
          className="flex max-w-[18rem] items-center gap-2 truncate text-gray-700 hover:text-blue-600 dark:text-gray-300 dark:hover:text-blue-300"
          onClick={() => setOpen((current) => !current)}
          type="button"
        >
          <span className="truncate">{user.email_address}</span>
          <ChevronDownIcon />
        </button>
        {open ? (
          <div className="absolute right-0 z-30 mt-2 w-56 rounded border border-gray-200 bg-white py-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-950">
            <Link className="block px-4 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800" to={`${prefix}/profiles/${user.id}`}>Profile</Link>
            <Link className="block px-4 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800" to={`${prefix}/settings`}>Settings</Link>
            {showTeamProfile ? <Link className="block px-4 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800" to={`${prefix}/profiles/${user.id}`}>My profile</Link> : null}
            {user.admin ? <Link className="block px-4 py-2 font-medium text-blue-600 hover:bg-gray-50 dark:text-blue-300 dark:hover:bg-gray-800" to={`${prefix}/admin`}>Admin</Link> : null}
            <button className="block w-full px-4 py-2 text-left text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800" onClick={switchToNewUi} type="button">Switch to new UI</button>
            <div className="my-1 border-t border-gray-100 dark:border-gray-800" />
            <form action="/session" method="post">
              {csrfToken ? <input name="authenticity_token" type="hidden" value={csrfToken} /> : null}
              <input name="_method" type="hidden" value="delete" />
              <button className="block w-full px-4 py-2 text-left text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800" type="submit">Sign out</button>
            </form>
          </div>
        ) : null}
      </div>
    </nav>
  )
}

function updateBootstrapLayoutVersion(payload: BootstrapPayload | undefined, layoutVersion: "v1" | "v2") {
  if (!payload?.current_user) return payload

  return {
    ...payload,
    current_user: {
      ...payload.current_user,
      layout_version: layoutVersion
    }
  }
}

function UserIcon() {
  return (
    <svg aria-hidden="true" className="h-7 w-7" fill="none" viewBox="0 0 24 24">
      <path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM4.75 20.25a7.25 7.25 0 0 1 14.5 0" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function ChevronDownIcon() {
  return (
    <svg aria-hidden="true" className="h-3 w-3 shrink-0" fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M5.23 7.21a.75.75 0 0 1 1.06.02L10 11.17l3.71-3.94a.75.75 0 1 1 1.08 1.04l-4.25 4.5a.75.75 0 0 1-1.08 0l-4.25-4.5a.75.75 0 0 1 .02-1.06Z" fillRule="evenodd" />
    </svg>
  )
}

function MoonIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M21 14.25A8.25 8.25 0 0 1 9.75 3a8.25 8.25 0 1 0 11.25 11.25Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function SunIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M12 4.75V3m0 18v-1.75M4.75 12H3m18 0h-1.75M6.87 6.87 5.64 5.64m12.72 12.72-1.23-1.23m0-10.26 1.23-1.23M5.64 18.36l1.23-1.23M15.25 12a3.25 3.25 0 1 1-6.5 0 3.25 3.25 0 0 1 6.5 0Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function FlashBanner({ flash }: { flash?: BootstrapPayload["flash"] }) {
  const [visible, setVisible] = useState(Boolean(flash?.alert || flash?.notice))
  const message = flash?.alert || flash?.notice

  useEffect(() => {
    setVisible(Boolean(message))
  }, [message])

  if (!message) return null
  if (!flash?.alert && flash?.notice && visible) return <NoticeToast message={flash.notice} onDismiss={() => setVisible(false)} />
  if (!visible) return null

  const tone = flash?.alert ? "border-red-200 bg-red-50 text-red-700" : "border-green-200 bg-green-50 text-green-700"
  return (
    <div className="mx-auto max-w-[96rem] px-6 pt-4">
      <p className={`inline-block rounded border px-3 py-2 text-sm ${tone}`}>{message}</p>
    </div>
  )
}

function SystemAlertsBanner({ alerts, prefix }: { alerts?: BootstrapPayload["system_alerts"]; prefix: string }) {
  const active = alerts || []
  if (active.length === 0) return null

  return (
    <section aria-label="System alerts" className="mx-auto max-w-[96rem] space-y-3 px-6 pt-4">
      {active.map((alert) => <SystemAlertItem alert={alert} key={alert.id} prefix={prefix} />)}
    </section>
  )
}

function SystemAlertItem({ alert, prefix }: { alert: NonNullable<BootstrapPayload["system_alerts"]>[number]; prefix: string }) {
  const tone = {
    alarm: "border-red-200 bg-red-50 text-red-900",
    warn: "border-amber-200 bg-amber-50 text-amber-900",
    info: "border-blue-200 bg-blue-50 text-blue-900"
  }[alert.severity] || "border-gray-200 bg-gray-50 text-gray-900"

  return (
    <article className={`rounded border px-4 py-3 text-sm ${tone}`}>
      <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 space-y-2">
          <h2 className="font-semibold">{alert.title}</h2>
          <p dangerouslySetInnerHTML={{ __html: alert.message }} />
          {alert.action_steps.length > 0 ? (
            <ul className="list-disc space-y-1 pl-5">
              {alert.action_steps.map((step) => (
                <li dangerouslySetInnerHTML={{ __html: step }} key={step} />
              ))}
            </ul>
          ) : null}
        </div>
        {alert.cta ? (
          <Link className="inline-flex shrink-0 items-center justify-center rounded border border-current px-3 py-1.5 font-medium hover:bg-white/60" to={withRoutePrefix(alert.cta.path, prefix)}>
            {alert.cta.text}
          </Link>
        ) : null}
      </div>
    </article>
  )
}

function AdminNavigation({ normalizedPath, prefix }: { normalizedPath: string; prefix: string }) {
  const items: Array<{ label: string; path: string; active: (path: string) => boolean }> = [
    { label: "Overview", path: "/admin", active: (path) => path === "/admin" },
    { label: "Stuck", path: "/admin/stuck", active: (path) => path === "/admin/stuck" },
    { label: "Users", path: "/admin/users", active: (path) => path.startsWith("/admin/users") },
    { label: "Queue", path: "/admin/queue/active", active: (path) => path.startsWith("/admin/queue") },
    { label: "Processes", path: "/admin/processes", active: (path) => path.startsWith("/admin/processes") },
    { label: "Console", path: "/admin/console", active: (path) => path === "/admin/console" },
    { label: "GitHub App", path: "/admin/github_app/register", active: (path) => path.startsWith("/admin/github_app") },
    { label: "Installations", path: "/admin/installations", active: (path) => path === "/admin/installations" },
    { label: "App settings", path: "/settings/edit", active: (path) => path === "/settings/edit" },
    { label: "Invitations", path: "/invitations", active: (path) => path === "/invitations" }
  ]

  return (
    <div className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <nav aria-label="Admin navigation" className="mx-auto flex max-w-[96rem] flex-wrap items-center gap-2 px-6 py-2 text-xs">
        {items.map((item) => {
          const className = adminNavLinkClass(item.active(normalizedPath))
          return <Link className={className} key={item.label} to={withRoutePrefix(item.path, prefix)}>{item.label}</Link>
        })}
      </nav>
    </div>
  )
}

function SettingsNavigation({ normalizedPath, prefix }: { normalizedPath: string; prefix: string }) {
  const items: Array<{ label: string; path: string; active: (path: string) => boolean }> = [
    { label: "My credentials", path: "/credentials/edit", active: (path) => path === "/settings" || path === "/credentials/edit" },
    { label: "Documents", path: "/documents", active: (path) => path === "/documents" },
    { label: "Templates", path: "/cron_templates", active: (path) => path.startsWith("/cron_templates") },
    { label: "Tags", path: "/tags", active: (path) => path === "/tags" }
  ]

  return (
    <div className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <nav aria-label="Settings navigation" className="mx-auto flex max-w-[96rem] flex-wrap items-center gap-2 px-6 py-2 text-xs">
        {items.map((item) => {
          const className = adminNavLinkClass(item.active(normalizedPath))
          return <Link className={className} key={item.label} to={withRoutePrefix(item.path, prefix)}>{item.label}</Link>
        })}
      </nav>
    </div>
  )
}

function showsAdminNavigation(pathname: string) {
  return pathname === "/admin" ||
    pathname.startsWith("/admin/") ||
    pathname === "/settings/edit" ||
    pathname === "/invitations"
}

function showsSettingsNavigation(pathname: string) {
  return pathname === "/settings" ||
    pathname === "/credentials/edit" ||
    pathname === "/documents" ||
    pathname === "/tags" ||
    pathname.startsWith("/cron_templates")
}

function redirectsToSetup(data: BootstrapPayload | null | undefined, normalizedPath: string) {
  if (!data?.setup || data.setup.complete) return false
  // Once the onboarding chat starts, tabs are revealed and free navigation is
  // allowed. Before that, keep stray dashboard/root visits on onboarding.
  if (data.setup.chat_started) return false
  return normalizedPath === "/" || normalizedPath.startsWith("/dashboard")
}

function showsPubliliusSyrusFooter(pathname: string) {
  return !pathname.startsWith("/chats")
}

function randomPubliliusSyrusQuote() {
  return PUBLILIUS_SYRUS_QUOTES[Math.floor(Math.random() * PUBLILIUS_SYRUS_QUOTES.length)]
}

function normalizedAppPath(pathname: string) {
  return pathname.replace(/^\/app-shell/, "") || "/"
}

function bugReportContext(pathname: string) {
  const normalized = normalizedAppPath(pathname)
  if (normalized === "/" || normalized === "/dashboard") return "Dashboard"

  const label = normalized
    .split("/")
    .filter(Boolean)
    .filter((segment) => !/^\d+$/.test(segment))
    .map((segment) => segment.replace(/_/g, " "))
    .join(" ")

  return label ? titleize(label) : "Syrus"
}

function titleize(value: string) {
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase())
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

function navLinkClass(active: boolean) {
  return `rounded px-1 py-1.5 font-medium sm:px-2.5 ${active ? "text-blue-700 dark:text-blue-300 sm:bg-blue-50 dark:sm:bg-blue-900/30" : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"}`
}

function accountLinkClass() {
  return "rounded bg-blue-100 px-2.5 py-1 font-medium text-blue-700 hover:bg-blue-200 dark:bg-blue-900/50 dark:text-blue-300 dark:hover:bg-blue-900"
}

function landingPrimaryButtonClass() {
  return "inline-flex items-center justify-center rounded bg-blue-700 px-4 py-2.5 text-sm font-semibold text-white hover:bg-blue-600"
}

function landingSecondaryButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-4 py-2.5 text-sm font-semibold text-gray-800 hover:bg-gray-50"
}

function adminNavLinkClass(active: boolean) {
  return `rounded px-2.5 py-1.5 font-medium ${active ? "bg-gray-900 text-white dark:bg-white dark:text-gray-900" : "text-gray-600 hover:bg-gray-100 hover:text-gray-900 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-white"}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}
