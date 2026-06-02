import { useQuery } from "@tanstack/react-query"
import { useEffect, useMemo, useState, type ReactNode } from "react"
import { Link, Route, Routes, useLocation } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { BugReportButton } from "../components/BugReportButton"
import { NoticeToast } from "../components/NoticeToast"
import { useAppEvents } from "../lib/useAppEvents"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { AdminConsole } from "./AdminConsole"
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
import { PersonalDocumentsRoute } from "./PersonalDocuments"
import { RepositoriesIndex } from "./Repositories"
import { RepositoryDetailRoute } from "./RepositoryDetail"
import { RepositoryDocumentsRoute } from "./RepositoryDocuments"
import { RepositoryFormRoute } from "./RepositoryForm"
import { RepositoryScheduledTasksRoute } from "./RepositoryScheduledTasks"
import { ScheduledTaskDetailRoute, ScheduledTaskFormRoute, ScheduledTasksIndex } from "./ScheduledTasks"
import { SmartFolders } from "./SmartFolders"
import { Tags } from "./Tags"

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
  { path: "/documents", element: <PersonalDocumentsRoute /> },
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

  return (
    <AppChrome initialBootstrap={initialBootstrap}>
      <Routes>
        <Route path="/" element={<DashboardRoute />} />
        {renderAppRoutes()}
        <Route path="*" element={<BootstrapShell initialBootstrap={initialBootstrap} />} />
      </Routes>
    </AppChrome>
  )
}

function renderAppRoutes() {
  return appRouteDefinitions.flatMap(({ path, element }) => [
    <Route element={element} key={path} path={path} />,
    <Route element={element} key={`/app-shell${path}`} path={`/app-shell${path}`} />
  ])
}

function AppChrome({ children, initialBootstrap }: { children: ReactNode; initialBootstrap: BootstrapPayload | null }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)
  const shouldLoadChromeBootstrap = initialBootstrap != null || normalizedPath === "/"
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
  const navItems: Array<{ label: string; to: string; active: boolean; desktopOnly?: boolean }> = user ? [
    { label: "Dashboard", to: `${prefix}/dashboard/jobs?view=list`, active: normalizedPath === "/" || normalizedPath.startsWith("/dashboard") },
    { label: "Repos", to: `${prefix}/repositories`, active: normalizedPath.startsWith("/repositories") },
    { label: "Schedules", to: `${prefix}/scheduled_tasks`, active: normalizedPath === "/scheduled_tasks" || normalizedPath.startsWith("/scheduled_tasks/"), desktopOnly: true }
  ] : []

  return (
    <div className="min-h-screen bg-gray-50 text-gray-900">
      <header className="border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-[96rem] items-center justify-between gap-3 px-6 py-3">
          <div className="flex min-w-0 items-center gap-5">
            <Link className="text-lg font-semibold text-gray-900" to={defaultChatPath}>Syrus</Link>
            <nav aria-label="Primary" className="flex flex-nowrap gap-1 text-sm">
              {navItems.map((item) => (
                <Link className={`${item.desktopOnly ? "hidden sm:inline-flex" : ""} ${navLinkClass(item.active)}`} key={item.label} to={item.to}>{item.label}</Link>
              ))}
            </nav>
          </div>
          <div className="flex shrink-0 items-center justify-end gap-2 text-xs text-gray-500">
            {user ? (
              <>
                <AccountNavigation csrfToken={data?.csrf_token} prefix={prefix} user={user} />
                {app ? <RevisionLink app={app} /> : null}
              </>
            ) : null}
          </div>
        </div>
      </header>
      {showsAdminNavigation(normalizedPath) ? <AdminNavigation normalizedPath={normalizedPath} prefix={prefix} /> : null}
      {showsSettingsNavigation(normalizedPath) ? <SettingsNavigation normalizedPath={normalizedPath} prefix={prefix} /> : null}
      <FlashBanner flash={data?.flash} />
      {children}
      {showsPubliliusSyrusFooter(normalizedPath) ? <PubliliusSyrusFooter quote={quote} /> : null}
      {user ? <BugReportButton context={bugReportContext(location.pathname)} /> : null}
    </div>
  )
}

function RevisionLink({ app }: { app: BootstrapPayload["app"] }) {
  const className = "hidden font-mono hover:text-blue-600 hover:underline sm:inline"
  if (!app.revision_url) return <span className="hidden font-mono sm:inline">{app.revision}</span>

  return (
    <a className={className} href={app.revision_url}>
      {app.revision}
    </a>
  )
}

function PubliliusSyrusFooter({ quote }: { quote: string }) {
  return (
    <footer className="mx-auto hidden max-w-[96rem] px-6 py-8 text-center text-xs text-gray-500 lg:block">
      <a className="hover:text-blue-600 hover:underline" href={PUBLILIUS_SYRUS_WIKIPEDIA_URL} rel="noopener" target="_blank">
        {quote}
      </a>
    </footer>
  )
}

function AccountNavigation({ csrfToken, prefix, user }: { csrfToken?: string; prefix: string; user: NonNullable<BootstrapPayload["current_user"]> }) {
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  return (
    <nav aria-label="Account" className="flex items-center gap-2">
      {user.admin ? <Link className={accountLinkClass()} to={`${prefix}/admin`}>admin</Link> : null}
      <Link aria-label="Account settings" className="inline-flex h-8 w-8 items-center justify-center text-gray-700 hover:text-blue-600 sm:hidden" to={`${prefix}/settings`}>
        <UserIcon />
      </Link>
      <div className="relative hidden sm:block" ref={menuRef}>
        <button
          aria-expanded={open}
          aria-haspopup="menu"
          className="flex max-w-[18rem] items-center gap-2 truncate text-gray-700 hover:text-blue-600"
          onClick={() => setOpen((current) => !current)}
          type="button"
        >
          <span className="truncate">{user.email_address}</span>
          <ChevronDownIcon />
        </button>
        {open ? (
          <div className="absolute right-0 z-30 mt-2 w-56 rounded border border-gray-200 bg-white py-1 text-sm shadow-lg">
            <Link className="block px-4 py-2 text-gray-700 hover:bg-gray-50" to={`${prefix}/settings`}>Settings</Link>
            {user.admin ? <Link className="block px-4 py-2 font-medium text-blue-600 hover:bg-gray-50" to={`${prefix}/admin`}>Admin</Link> : null}
            <div className="my-1 border-t border-gray-100" />
            <form action="/session" method="post">
              {csrfToken ? <input name="authenticity_token" type="hidden" value={csrfToken} /> : null}
              <input name="_method" type="hidden" value="delete" />
              <button className="block w-full px-4 py-2 text-left text-gray-700 hover:bg-gray-50" type="submit">Sign out</button>
            </form>
          </div>
        ) : null}
      </div>
    </nav>
  )
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
    <div className="border-b border-gray-200 bg-white">
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
    <div className="border-b border-gray-200 bg-white">
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
  return `rounded px-1 py-1.5 font-medium sm:px-2.5 ${active ? "text-blue-700 sm:bg-blue-50" : "text-gray-700 hover:bg-gray-100"}`
}

function accountLinkClass() {
  return "rounded bg-blue-100 px-2.5 py-1 font-medium text-blue-700 hover:bg-blue-200"
}

function adminNavLinkClass(active: boolean) {
  return `rounded px-2.5 py-1.5 font-medium ${active ? "bg-gray-900 text-white" : "text-gray-600 hover:bg-gray-100 hover:text-gray-900"}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}
