import { useQuery, useQueryClient } from "@tanstack/react-query"
import { type FormEvent, type KeyboardEvent, type MouseEvent, type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { Link, Navigate, Outlet, useLocation, useNavigate } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { createEmptyChat, fetchChat, fetchChats, fetchMoreChatsForGroup, hideChat, updateChatPinned, type ChatGroupRecord, type ChatNavRecord, type ChatPayload, type ChatsIndexPayload } from "../api/chats"
import { patchJson } from "../api/client"
import { dashboardApiSearch, fetchDashboard, type DashboardPayload, type DashboardSubject } from "../api/dashboard"
import { fetchTerminalSessions } from "../api/terminal"
import { BugReportButton } from "../components/BugReportButton"
import { CloseIcon } from "../components/CloseIcon"
import { DashboardSmartFolderNav } from "../components/DashboardSmartFolderNav"
import { NoticeToast } from "../components/NoticeToast"
import { NotificationsBell } from "../components/Notifications"
import { PinIcon } from "../components/PinIcon"
import { SyrusBrand } from "../components/SyrusBrand"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { updateRecentChatCache } from "../lib/chatCache"
import { firstUnstartedChat } from "../lib/unstartedChat"
import { chatQueryKey } from "./Chat"

const SIDEBAR_WIDTH_KEY = "syrus.sidebar.width"
const SIDEBAR_DEFAULT_WIDTH = 240
const SIDEBAR_MIN_WIDTH = 208
const SIDEBAR_MAX_WIDTH = 420
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

export function AppChromeV2({ children, initialBootstrap }: { children?: ReactNode; initialBootstrap: BootstrapPayload | null }) {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const normalizedPath = normalizedAppPath(location.pathname)
  const shouldLoadChromeBootstrap = initialBootstrap == null && !isAuthPath(normalizedPath)
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: shouldLoadChromeBootstrap,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  const data = bootstrap.data ?? initialBootstrap
  const user = data?.current_user
  const showAdminSubnav = Boolean(user?.admin && isAdminPath(normalizedPath))
  const quote = useMemo(randomPubliliusSyrusQuote, [])
  const showQuote = !normalizedPath.startsWith("/chats") && !normalizedPath.startsWith("/terminal")
  const showDashboardSidebarSubjects = Boolean(data?.feature_flags?.v2_sidebar_subject_selector)
  const inOnboarding = Boolean(data?.setup && !data.setup.complete)
  const onboardingChatStarted = Boolean(data?.setup?.chat_started)
  const tabsHidden = inOnboarding && !onboardingChatStarted
  const [drawerOpen, setDrawerOpen] = useState(false)
  const [mobileBrandFloating, setMobileBrandFloating] = useState(false)
  const [sidebarWidth, setSidebarWidth] = useState(storedSidebarWidth)
  const [sidebarResize, setSidebarResize] = useState<{ startX: number; startWidth: number } | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const mainRef = useRef<HTMLElement | null>(null)
  const pageContent = redirectsToSetup(data, normalizedPath)
    ? <Navigate replace to={`${prefix}/onboarding`} />
    : children ?? <Outlet />

  const terminalSessionCount = useTerminalSessionCount(Boolean(data?.feature_flags?.terminal && user))
  const navItems: Array<{ label: string; to: string; active: boolean; icon: ReactNode; badge?: number }> = user ? [
    ...(inOnboarding ? [{ label: "Setup", to: `${prefix}/onboarding`, active: normalizedPath === "/onboarding", icon: <SetupIcon /> }] : []),
    ...(tabsHidden ? [] : [
      { label: "Dashboard", to: `${prefix}/dashboard/jobs`, active: normalizedPath === "/" || normalizedPath.startsWith("/dashboard"), icon: <DashboardIcon /> },
      { label: "Spending", to: `${prefix}/insights/spending`, active: normalizedPath.startsWith("/insights/spending"), icon: <SpendingIcon /> },
      { label: "Repositories", to: `${prefix}/repositories`, active: normalizedPath.startsWith("/repositories"), icon: <RepositoryIcon /> },
      { label: "Schedules", to: `${prefix}/scheduled_tasks`, active: normalizedPath === "/scheduled_tasks" || normalizedPath.startsWith("/scheduled_tasks/"), icon: <ScheduleIcon /> },
      ...(data?.feature_flags?.terminal ? [{
        label: "Terminal",
        to: `${prefix}/terminal`,
        active: normalizedPath.startsWith("/terminal"),
        icon: <TerminalIcon />,
        badge: terminalSessionCount
      }] : []),
      ...(data && data.team_user_count > 1 ? [{ label: "Team", to: `${prefix}/profiles`, active: normalizedPath.startsWith("/profiles"), icon: <TeamIcon /> }] : [])
    ])
  ] : []

  async function startChat() {
    if (normalizedPath === "/chats/new") return

    setDrawerOpen(false)
    const unstartedChat = firstUnstartedChat(queryClient.getQueryData<ChatsIndexPayload>(["chats", "recent"]))
    if (unstartedChat) {
      navigate(withRoutePrefix(unstartedChat.chat_path, prefix))
      return
    }

    try {
      const created = await createEmptyChat()
      updateRecentChatCache(queryClient, created.chat, { prepend: true })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    } catch (_error) {
      setNotice("Unable to start chat.")
    }
  }

  useEffect(() => {
    setMobileBrandFloating((mainRef.current?.scrollTop || 0) > 8)
  }, [location.pathname])

  useEffect(() => {
    if (!sidebarResize) return

    const resize = sidebarResize

    function handleMouseMove(event: globalThis.MouseEvent) {
      updateSidebarWidth(resize.startWidth + event.clientX - resize.startX)
    }

    function handleMouseUp() {
      setSidebarResize(null)
    }

    document.body.classList.add("select-none", "cursor-col-resize")
    window.addEventListener("mousemove", handleMouseMove)
    window.addEventListener("mouseup", handleMouseUp)

    return () => {
      document.body.classList.remove("select-none", "cursor-col-resize")
      window.removeEventListener("mousemove", handleMouseMove)
      window.removeEventListener("mouseup", handleMouseUp)
    }
  }, [sidebarResize])

  function updateSidebarWidth(width: number) {
    const nextWidth = clampSidebarWidth(width)
    setSidebarWidth(nextWidth)
    storeSidebarWidth(nextWidth)
  }

  function startSidebarResize(event: MouseEvent<HTMLDivElement>) {
    event.preventDefault()
    setSidebarResize({ startX: event.clientX, startWidth: sidebarWidth })
  }

  function resizeSidebarWithKeyboard(event: KeyboardEvent<HTMLDivElement>) {
    if (event.key === "ArrowLeft") {
      event.preventDefault()
      updateSidebarWidth(sidebarWidth - 16)
    } else if (event.key === "ArrowRight") {
      event.preventDefault()
      updateSidebarWidth(sidebarWidth + 16)
    } else if (event.key === "Home") {
      event.preventDefault()
      updateSidebarWidth(SIDEBAR_MIN_WIDTH)
    } else if (event.key === "End") {
      event.preventDefault()
      updateSidebarWidth(SIDEBAR_MAX_WIDTH)
    }
  }

  function handleMainScroll() {
    const nextFloating = (mainRef.current?.scrollTop || 0) > 8
    setMobileBrandFloating((current) => current === nextFloating ? current : nextFloating)
  }

  return (
    <div className="flex h-screen overflow-hidden bg-gray-50 text-gray-900 dark:bg-gray-900 dark:text-white">
      <aside className="relative hidden shrink-0 lg:flex" style={{ width: `${sidebarWidth}px` }}>
        <SidebarContent
          csrfToken={data?.csrf_token}
          dashboardSubnavEnabled={true}
          navItems={navItems}
          onCloseDrawer={() => setDrawerOpen(false)}
          onNotice={setNotice}
          onStartChat={startChat}
          prefix={prefix}
          showTeamProfile={(data?.team_user_count || 0) > 1}
          showDashboardSidebarSubjects={showDashboardSidebarSubjects}
          user={user}
        />
        <div
          aria-label="Resize sidebar"
          aria-orientation="vertical"
          aria-valuemax={SIDEBAR_MAX_WIDTH}
          aria-valuemin={SIDEBAR_MIN_WIDTH}
          aria-valuenow={sidebarWidth}
          className="absolute inset-y-0 -right-1 z-10 w-2 cursor-col-resize rounded-sm outline-none transition-colors hover:bg-blue-500/30 focus-visible:bg-blue-500/40"
          onKeyDown={resizeSidebarWithKeyboard}
          onMouseDown={startSidebarResize}
          role="separator"
          tabIndex={0}
        />
      </aside>

      {mobileBrandFloating && !drawerOpen ? (
        <>
          <button
            aria-label="Open sidebar"
            className="fixed left-3 top-3 z-30 inline-flex h-11 w-11 items-center justify-center rounded border border-gray-200 bg-white text-gray-900 shadow-lg hover:bg-gray-50 hover:text-blue-600 dark:border-gray-800 dark:bg-gray-950 dark:text-white dark:hover:bg-gray-900 dark:hover:text-blue-300 lg:hidden"
            onClick={() => setDrawerOpen(true)}
            type="button"
          >
            <img alt="" aria-hidden="true" className="h-6 w-6 rounded" src="/icon.png" />
          </button>
          {user ? (
            <div className="fixed right-3 top-3 z-30 inline-flex h-11 w-11 items-center justify-center rounded border border-gray-200 bg-white shadow-lg dark:border-gray-800 dark:bg-gray-950 lg:hidden">
              <NotificationsBell initialUnreadCount={user.notification_unread_count ?? 0} prefix={prefix} />
            </div>
          ) : null}
        </>
      ) : null}

      {drawerOpen ? (
        <div className="fixed inset-0 z-40 bg-white dark:bg-gray-950 lg:hidden">
          <SidebarContent
            csrfToken={data?.csrf_token}
            dashboardSubnavEnabled={false}
            navItems={navItems}
            onCloseDrawer={() => setDrawerOpen(false)}
            onNotice={setNotice}
            onStartChat={startChat}
            prefix={prefix}
            showTeamProfile={(data?.team_user_count || 0) > 1}
            showDashboardSidebarSubjects={showDashboardSidebarSubjects}
            user={user}
          />
        </div>
      ) : null}

      <main className="min-w-0 flex-1 overflow-auto" onScroll={handleMainScroll} ref={mainRef}>
        <div className="flex w-full items-center justify-between gap-3 border-b border-gray-200 bg-white px-4 py-3 dark:border-gray-800 dark:bg-gray-950 lg:hidden">
          <button
            aria-label="Open sidebar"
            className="min-w-0 text-left text-lg font-semibold text-gray-900 hover:text-blue-600 dark:text-white dark:hover:text-blue-300"
            onClick={() => setDrawerOpen(true)}
            type="button"
          >
            <SyrusBrand />
          </button>
          {user ? <NotificationsBell initialUnreadCount={user.notification_unread_count ?? 0} prefix={prefix} /> : null}
        </div>
        <SystemAlertsBanner alerts={data?.system_alerts} prefix={prefix} />
        <FlashBanner flash={data?.flash} />
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {showAdminSubnav ? (
          <div className="min-h-full min-w-0">
            <AdminSubnav featureFlags={data?.feature_flags || {}} normalizedPath={normalizedPath} prefix={prefix} />
            <div className="min-w-0 flex-1">
              {pageContent}
            </div>
          </div>
        ) : (
          pageContent
        )}
        {showQuote ? <PubliliusSyrusFooter quote={quote} /> : null}
      </main>
      {notice ? <NoticeToast message={notice} onDismiss={() => setNotice(null)} /> : null}
      {user ? <BugReportButton context={bugReportContext(location.pathname)} position="bottom-right" /> : null}
    </div>
  )
}

function randomPubliliusSyrusQuote() {
  return PUBLILIUS_SYRUS_QUOTES[Math.floor(Math.random() * PUBLILIUS_SYRUS_QUOTES.length)]
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

const adminNavItems = [
  { label: "Overview", to: "/admin", paths: ["/admin"] },
  { label: "Queue", to: "/admin/queue", paths: ["/admin/queue"] },
  { label: "Stuck", to: "/admin/stuck", paths: ["/admin/stuck"] },
  { label: "Processes", to: "/admin/processes", paths: ["/admin/processes"] },
  { label: "Users", to: "/admin/users", paths: ["/admin/users"] },
  { label: "Console", to: "/admin/console", paths: ["/admin/console"] },
  { label: "Installations", to: "/admin/installations", paths: ["/admin/installations"] },
  { label: "GitHub App", to: "/admin/github_app/register", paths: ["/admin/github_app"] },
  { label: "Invitations", to: "/invitations", paths: ["/invitations"] },
  { label: "Settings", to: "/settings/edit", paths: ["/settings/edit"] }
]

function AdminSubnav({ featureFlags, normalizedPath, prefix }: { featureFlags: Record<string, boolean>; normalizedPath: string; prefix: string }) {
  const items = [
    ...adminNavItems.slice(0, -1),
    ...(hasFeatureFlags(featureFlags) ? [{ label: "Features", to: "/admin/features", paths: ["/admin/features"] }] : []),
    adminNavItems[adminNavItems.length - 1]
  ]

  return (
    <div className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <nav aria-label="Admin" className="flex gap-2 overflow-x-auto px-4 py-3 text-sm">
        {items.map((item) => {
          const active = item.paths.some((path) => adminNavItemActive(normalizedPath, path))

          return (
            <Link className={adminSubnavLinkClass(active)} key={item.label} to={withRoutePrefix(item.to, prefix)}>
              {item.label}
            </Link>
          )
        })}
      </nav>
    </div>
  )
}

function hasFeatureFlags(featureFlags: Record<string, boolean>) {
  return Object.keys(featureFlags).length > 0
}

function SidebarContent({
  csrfToken,
  dashboardSubnavEnabled,
  navItems,
  onCloseDrawer,
  onNotice,
  onStartChat,
  prefix,
  showDashboardSidebarSubjects,
  showTeamProfile,
  user
}: {
  csrfToken?: string
  dashboardSubnavEnabled: boolean
  navItems: Array<{ label: string; to: string; active: boolean; icon: ReactNode; badge?: number }>
  onCloseDrawer: () => void
  onNotice: (message: string | null) => void
  onStartChat: () => void
  prefix: string
  showDashboardSidebarSubjects: boolean
  showTeamProfile: boolean
  user: BootstrapPayload["current_user"] | undefined
}) {
  const dashboardActive = navItems.some((item) => item.label === "Dashboard" && item.active)
  const [dashboardNavOpen, setDashboardNavOpen] = useState(dashboardActive)

  useEffect(() => {
    setDashboardNavOpen(dashboardActive)
  }, [dashboardActive])

  function handlePrimaryNavClick(item: { label: string; active: boolean }, event: MouseEvent<HTMLAnchorElement>) {
    if (item.label === "Dashboard" && dashboardSubnavEnabled) {
      if (item.active) {
        event.preventDefault()
        setDashboardNavOpen((open) => !open)
        return
      }

      setDashboardNavOpen(true)
      onCloseDrawer()
      return
    }

    setDashboardNavOpen(false)
    onCloseDrawer()
  }

  return (
    <div className="flex h-full w-full flex-col border-r border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <div className="shrink-0 border-b border-gray-200 px-4 py-4 dark:border-gray-800">
        <div className="flex items-center justify-between gap-3">
          <Link className="text-lg font-semibold text-gray-900 dark:text-white" onClick={onCloseDrawer} to={prefix || "/"}><SyrusBrand /></Link>
          <div className="flex items-center gap-1">
            {user ? <NotificationsBell initialUnreadCount={user.notification_unread_count ?? 0} onNavigate={onCloseDrawer} prefix={prefix} /> : null}
            <button
              aria-label="Close sidebar"
              className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-700 hover:bg-gray-100 hover:text-blue-600 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300 lg:hidden"
              onClick={onCloseDrawer}
              type="button"
            >
              <CloseIcon />
            </button>
          </div>
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="sticky top-0 z-20 space-y-3 bg-white px-3 py-4 dark:bg-gray-950">
          <button
            className="inline-flex w-full items-center justify-center gap-2 rounded bg-blue-700 px-3 py-2 text-sm font-semibold text-white hover:bg-blue-600 disabled:cursor-not-allowed disabled:bg-gray-300"
            disabled={!user}
            onClick={onStartChat}
            type="button"
          >
            <PlusIcon />
            <span>New Chat</span>
          </button>
          <SidebarSearchForm onCloseDrawer={onCloseDrawer} prefix={prefix} />
        </div>
        <div className="px-3 pb-4">
          <nav aria-label="Primary" className="flex flex-col gap-1 text-sm">
            {navItems.map((item) => {
              const link = (
                <Link className={sidebarLinkClass(item.active)} key={item.label} onClick={(event) => handlePrimaryNavClick(item, event)} to={item.to}>
                  {item.icon}
                  <span>{item.label}</span>
                  {item.badge ? <span className="ml-auto rounded-full bg-red-500 px-1.5 py-0.5 text-xs leading-none text-white">{item.badge}</span> : null}
                </Link>
              )

              if (item.label !== "Dashboard") return link

              return (
                <div className="space-y-1" key={item.label}>
                  {link}
                  {dashboardSubnavEnabled ? (
                    <SidebarDashboardNav expanded={dashboardNavOpen} onCloseDrawer={onCloseDrawer} prefix={prefix} showSubjects={showDashboardSidebarSubjects} />
                  ) : null}
                </div>
              )
            })}
          </nav>
        </div>
        <RecentChatsSidebar onCloseDrawer={onCloseDrawer} onNotice={onNotice} prefix={prefix} userPresent={Boolean(user)} />
      </div>
      <div className="shrink-0 border-t border-gray-200 p-3 dark:border-gray-800">
        {user ? (
          <nav aria-label="Account">
            <SettingsPopup
              csrfToken={csrfToken}
              onCloseDrawer={onCloseDrawer}
              prefix={prefix}
              showTeamProfile={showTeamProfile}
              user={user}
            />
          </nav>
        ) : null}
      </div>
    </div>
  )
}

function SidebarSearchForm({ onCloseDrawer, prefix }: { onCloseDrawer: () => void; prefix: string }) {
  const location = useLocation()
  const navigate = useNavigate()
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [query, setQuery] = useState(() => searchQueryFromLocation(location.search))
  const userEditedRef = useRef(false)

  function submitSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    navigateToSearch(query)
  }

  function navigateToSearch(value: string) {
    const trimmedQuery = value.trim()
    onCloseDrawer()
    navigate(trimmedQuery ? `${prefix}/search?q=${encodeURIComponent(trimmedQuery)}` : `${prefix}/search`)
  }

  useEffect(() => {
    userEditedRef.current = false
    setQuery(searchQueryFromLocation(location.search))
  }, [location.search])

  useEffect(() => {
    if (!userEditedRef.current) return

    const timer = window.setTimeout(() => {
      navigateToSearch(query)
    }, 300)

    return () => window.clearTimeout(timer)
  }, [query])

  useEffect(() => {
    function focusSearch(event: globalThis.KeyboardEvent) {
      const target = event.target
      const targetElement = target instanceof HTMLElement ? target : null
      const typingTarget = targetElement?.tagName === "INPUT" ||
        targetElement?.tagName === "TEXTAREA" ||
        targetElement?.isContentEditable
      const shortcut = event.key === "/" || ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k")
      if (!shortcut || typingTarget) return

      event.preventDefault()
      inputRef.current?.focus()
      inputRef.current?.select()
    }

    window.addEventListener("keydown", focusSearch)
    return () => window.removeEventListener("keydown", focusSearch)
  }, [])

  return (
    <form className="relative" onSubmit={submitSearch} role="search">
      <label className="sr-only" htmlFor="sidebar-global-search">Search Syrus</label>
      <SearchIcon />
      <input
        className="block h-9 w-full rounded border border-gray-200 bg-gray-50 py-1.5 pl-9 pr-3 text-sm text-gray-900 placeholder:text-gray-400 focus:border-blue-500 focus:bg-white focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500 dark:focus:border-blue-400 dark:focus:bg-gray-950 dark:focus:ring-blue-400"
        id="sidebar-global-search"
        onChange={(event) => {
          userEditedRef.current = true
          setQuery(event.target.value)
        }}
        placeholder="Search..."
        ref={inputRef}
        type="search"
        value={query}
      />
    </form>
  )
}

function searchQueryFromLocation(search: string) {
  return new URLSearchParams(search).get("q") || ""
}

function SidebarDashboardNav({ expanded, onCloseDrawer, prefix, showSubjects }: { expanded: boolean; onCloseDrawer: () => void; prefix: string; showSubjects: boolean }) {
  const location = useLocation()
  const isDashboard = location.pathname.includes("/dashboard")
  const search = dashboardApiSearch(location.pathname, location.search)
  const [renderedPayload, setRenderedPayload] = useState<DashboardPayload | null>(null)
  const dashboard = useQuery({
    queryKey: ["dashboard", search],
    queryFn: ({ signal }) => fetchDashboard(search, { signal }),
    enabled: isDashboard,
    placeholderData: (previousData) => previousData
  })

  useEffect(() => {
    if (dashboard.data) setRenderedPayload(dashboard.data)
  }, [dashboard.data])

  const payload = dashboard.data ?? renderedPayload
  if (!payload) return null

  const inertAttributes = expanded ? {} : { inert: "" }

  return (
    <div
      {...inertAttributes}
      aria-hidden={!expanded}
      className={`grid overflow-hidden transition-[grid-template-rows] duration-200 ease-out ${expanded ? "grid-rows-[1fr]" : "grid-rows-[0fr]"}`}
    >
      <div className={`min-h-0 overflow-hidden transition-opacity duration-150 ease-out ${expanded ? "opacity-100 delay-75" : "opacity-0"}`}>
        <div className="space-y-3 pl-7 pt-1">
          {showSubjects ? <SidebarDashboardSubjects onCloseDrawer={onCloseDrawer} payload={payload} prefix={prefix} /> : null}
          <DashboardSmartFolderNav payload={payload} prefix={prefix} search={location.search} />
        </div>
      </div>
    </div>
  )
}

function SidebarDashboardSubjects({ onCloseDrawer, payload, prefix }: { onCloseDrawer: () => void; payload: DashboardPayload; prefix: string }) {
  const subjects: Array<{ key: DashboardSubject; label: string; path: string }> = [
    { key: "epic", label: "Epics", path: "/dashboard/epics" },
    { key: "job", label: "Jobs", path: "/dashboard/jobs" },
    { key: "workflow", label: "Workflows", path: "/dashboard/workflows" }
  ]

  return (
    <nav aria-label="Dashboard sections" className="inline-flex max-w-full flex-wrap overflow-hidden rounded border border-gray-300 bg-white text-xs dark:border-gray-700 dark:bg-gray-900">
      {subjects.map((subject) => (
        <Link
          className={`whitespace-nowrap px-1.5 py-1.5 text-center font-medium ${payload.subject === subject.key ? "bg-blue-50 text-blue-700 ring-1 ring-inset ring-blue-600 dark:bg-blue-950 dark:text-blue-200 dark:ring-blue-500" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"}`}
          key={subject.key}
          onClick={onCloseDrawer}
          to={withRoutePrefix(subject.path, prefix)}
        >
          {subject.label}
        </Link>
      ))}
    </nav>
  )
}

type ChatSection = {
  key: string
  label: string
  repository_id: number | null
  chats: ChatNavRecord[]
  has_more: boolean
}

function RecentChatsSidebar({ onCloseDrawer, onNotice, prefix, userPresent }: { onCloseDrawer: () => void; onNotice: (message: string | null) => void; prefix: string; userPresent: boolean }) {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(() => new Set())
  const [loadedSections, setLoadedSections] = useState<Record<string, { chats: ChatNavRecord[]; has_more: boolean }>>({})
  const [loadingSections, setLoadingSections] = useState<Set<string>>(() => new Set())
  const [hidingChatIds, setHidingChatIds] = useState<Set<number>>(() => new Set())
  const activeChatId = activeChatIdFromPath(location.pathname)
  const chats = useQuery({
    queryKey: ["chats", "recent"],
    queryFn: fetchChats,
    enabled: userPresent,
    staleTime: 30_000
  })
  const sections = useMemo(() => chatSectionsFromPayload(chats.data?.groups || [], loadedSections), [chats.data?.groups, loadedSections])

  function showLess(key: string) {
    setLoadedSections((current) => {
      const next = { ...current }
      delete next[key]
      return next
    })
  }

  function toggleCollapsedSection(key: string) {
    setCollapsedSections((current) => {
      const next = new Set(current)
      if (next.has(key)) {
        next.delete(key)
      } else {
        next.add(key)
      }
      return next
    })
  }

  function showMore(section: ChatSection) {
    const beforeChat = section.chats[section.chats.length - 1]
    if (!beforeChat || loadingSections.has(section.key)) return

    setLoadingSections((current) => new Set(current).add(section.key))
    void fetchMoreChatsForGroup(section.repository_id, beforeChat.id).then((payload) => {
      setLoadedSections((current) => {
        const existing = current[section.key]
        const existingIds = new Set([
          ...section.chats.map((chat) => chat.id),
          ...(existing?.chats.map((chat) => chat.id) || [])
        ])
        const nextChats = payload.chats.filter((chat) => !existingIds.has(chat.id))

        return {
          ...current,
          [section.key]: {
            chats: [...(existing?.chats || []), ...nextChats],
            has_more: payload.has_more
          }
        }
      })
    }).finally(() => {
      setLoadingSections((current) => {
        const next = new Set(current)
        next.delete(section.key)
        return next
      })
    })
  }

  function hideRecentChat(chat: ChatNavRecord) {
    if (hidingChatIds.has(chat.id)) return

    setHidingChatIds((current) => new Set(current).add(chat.id))
    removeChatFromRecentLists(chat.id)
    void hideChat(chat.id).then(() => {
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
      void queryClient.invalidateQueries({ queryKey: ["hidden-chats"] })
      if (chat.id === activeChatId) navigate(`${prefix}/dashboard/jobs`)
    }).catch(() => {
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }).finally(() => {
      setHidingChatIds((current) => {
        const next = new Set(current)
        next.delete(chat.id)
        return next
      })
    })
  }

  function togglePin(chat: ChatNavRecord) {
    void updateChatPinned(chat.id, !chat.pinned).then(() => {
      onNotice(null)
      void queryClient.invalidateQueries({ queryKey: ["chats", "recent"] })
    }).catch(() => {
      onNotice("Unable to update chat pin.")
    })
  }

  function removeChatFromRecentLists(chatId: number) {
    queryClient.setQueryData<ChatsIndexPayload>(["chats", "recent"], (current) => {
      if (!current) return current

      return {
        ...current,
        groups: current.groups
          .map((group) => ({ ...group, chats: group.chats.filter((chat) => chat.id !== chatId) }))
          .filter((group) => group.chats.length > 0)
      }
    })
    setLoadedSections((current) => {
      const next: Record<string, { chats: ChatNavRecord[]; has_more: boolean }> = {}
      Object.entries(current).forEach(([key, value]) => {
        next[key] = { ...value, chats: value.chats.filter((chat) => chat.id !== chatId) }
      })
      return next
    })
  }

  if (!userPresent) return null

  return (
    <div className="px-3 pb-4">
      <nav aria-label="Recent chats" className="space-y-4">
        {sections.map((section) => {
          const collapsed = collapsedSections.has(section.key)
          const loaded = loadedSections[section.key]
          const loading = loadingSections.has(section.key)
          const visibleChats = collapsed ? [] : section.chats
          const canShowMore = !collapsed && section.has_more
          const canShowLess = !collapsed && Boolean(loaded)

          return (
            <section className="space-y-1" key={section.key}>
              <h2>
                <button
                  aria-expanded={!collapsed}
                  className="flex w-full min-w-0 items-center gap-1 rounded px-2 py-1 text-left text-[0.68rem] font-semibold uppercase tracking-normal text-gray-500 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
                  onClick={() => toggleCollapsedSection(section.key)}
                  type="button"
                >
                  <ChevronDownIcon className={collapsed ? "-rotate-90" : ""} />
                  <span className="min-w-0 flex-1 truncate">{section.label}</span>
                </button>
              </h2>
              <div className="space-y-0.5">
                {visibleChats.map((chat) => {
                  const active = chat.current || chat.id === activeChatId
                  const unread = chat.unread && !active
                  return (
                    <div className="group relative flex min-w-0 items-center" key={chat.id}>
                      <Link
                        className={`${recentChatLinkClass(active)} pr-9`}
                        onClick={onCloseDrawer}
                        to={withRoutePrefix(chat.chat_path, prefix)}
                      >
                        <RecentChatActivityMarker active={Boolean(chat.turn_in_flight || chat.agent_busy)} unread={unread} />
                        {chat.pending_proposal_count > 0 && (
                          <span className="mt-1 h-2 w-2 shrink-0 rounded-full bg-amber-400 dark:bg-amber-500" />
                        )}
                        {chat.pinned ? (
                          <PinIcon className="mt-0.5 h-3.5 w-3.5 shrink-0 text-blue-600 dark:text-blue-300" />
                        ) : null}
                        <span className={`min-w-0 flex-1 truncate ${unread ? "font-semibold" : "font-medium"}`}>{sidebarChatTitle(chat)}</span>
                      </Link>
                      <RecentChatActionsMenu
                        chat={chat}
                        disabled={hidingChatIds.has(chat.id)}
                        onHide={() => hideRecentChat(chat)}
                        onTogglePin={() => togglePin(chat)}
                        search={location.search}
                      />
                    </div>
                  )
                })}
              </div>
              {canShowMore || canShowLess ? (
                <div className="ml-6 flex flex-wrap gap-1">
                  {canShowMore ? (
                    <button
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-blue-700 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
                      disabled={loading}
                      onClick={() => showMore(section)}
                      type="button"
                    >
                      {loading ? "Loading..." : "Show more"}
                    </button>
                  ) : null}
                  {canShowLess ? (
                    <button
                      className="rounded px-2 py-1 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-blue-300"
                      onClick={() => showLess(section.key)}
                      type="button"
                    >
                      Show less
                    </button>
                  ) : null}
                </div>
              ) : null}
            </section>
          )
        })}
      </nav>
    </div>
  )
}

function RecentChatActivityMarker({ active, unread }: { active: boolean; unread: boolean }) {
  if (active) {
    return (
      <span aria-hidden="true" className="mt-[0.35rem] inline-flex h-2 w-3.5 shrink-0 items-center justify-between" title="Chat turn active">
        {[0, 1, 2].map((index) => (
          <span
            aria-hidden="true"
            className="h-1 w-1 animate-bounce rounded-full bg-blue-600 dark:bg-blue-300"
            key={index}
            style={{ animationDelay: `${index * 140}ms` }}
          />
        ))}
      </span>
    )
  }

  return <span className={`mt-1 h-2 w-2 shrink-0 rounded-full ${unread ? "bg-blue-600 dark:bg-blue-400" : "bg-transparent"}`} />
}

function RecentChatActionsMenu({ chat, disabled, onHide, onTogglePin, search }: {
  chat: ChatNavRecord
  disabled: boolean
  onHide: () => void
  onTogglePin: () => void
  search: string
}) {
  const location = useLocation()
  const queryClient = useQueryClient()
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const active = chat.current || chat.id === activeChatIdFromPath(location.pathname)
  const queryKey = chatQueryKey(String(chat.id), search)
  const cachedChatData = queryClient.getQueryData<ChatPayload>(queryKey)
  const chatBookmarks = useQuery({
    queryKey,
    queryFn: () => fetchChat(String(chat.id), search),
    enabled: open && !cachedChatData
  })
  const chatData = open ? cachedChatData ?? chatBookmarks.data : undefined
  const bookmarks = chatData?.bookmarks ?? []
  const loadingBookmarks = open && !chatData && chatBookmarks.isPending

  return (
    <div className="absolute right-1 top-1/2 -translate-y-1/2" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-label={`Chat actions for ${sidebarChatTitle(chat)}`}
        className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 opacity-0 hover:bg-blue-100 hover:text-blue-700 focus:opacity-100 dark:text-gray-400 dark:hover:bg-blue-900 dark:hover:text-blue-200 group-hover:opacity-100"
        onClick={() => setOpen((value) => !value)}
        type="button"
      >
        ...
      </button>
      {open ? (
        <div className="absolute bottom-full right-0 z-20 mb-1 w-48 rounded border border-gray-200 bg-white py-1 text-xs shadow-lg dark:border-gray-700 dark:bg-gray-950">
          {loadingBookmarks ? (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">Loading bookmarks...</div>
          ) : bookmarks.length > 0 ? (
            <>
              <div className="px-3 py-2 font-semibold text-gray-700 dark:text-gray-200">Bookmarks</div>
              {bookmarks.map((bookmark) => {
                const anchorMessageId = bookmark.anchor_message_id ?? bookmark.chat_message_id

                return (
                  <a
                    className="block truncate px-3 py-2 text-gray-700 hover:bg-blue-50 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-blue-950 dark:hover:text-blue-200"
                    href={active ? `#message-${anchorMessageId}` : withRoutePrefix(`${chat.chat_path}#message-${anchorMessageId}`, prefix)}
                    key={bookmark.id}
                    onClick={() => setOpen(false)}
                  >
                    {bookmark.label}
                  </a>
                )
              })}
            </>
          ) : (
            <div className="px-3 py-2 text-gray-400 dark:text-gray-500">No bookmarks yet</div>
          )}
          <button
            className="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
            onClick={() => {
              onTogglePin()
              setOpen(false)
            }}
            type="button"
          >
            <PinIcon className="h-4 w-4 shrink-0" />
            {chat.pinned ? "Unpin chat" : "Pin chat"}
          </button>
          <div className="my-1 border-t border-gray-200 dark:border-gray-700" />
          <button
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:text-red-300 dark:hover:bg-red-950/40"
            disabled={disabled}
            onClick={() => {
              setOpen(false)
              onHide()
            }}
            type="button"
          >
            <HideIcon />
            <span>Hide Chat</span>
          </button>
        </div>
      ) : null}
    </div>
  )
}

function SettingsPopup({ csrfToken, onCloseDrawer, prefix, showTeamProfile, user }: {
  csrfToken?: string
  onCloseDrawer: () => void
  prefix: string
  showTeamProfile: boolean
  user: NonNullable<BootstrapPayload["current_user"]>
}) {
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
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) => updateBootstrapTheme(current, payload.theme))
    }).catch(() => {
      document.documentElement.classList.toggle("dark", theme === "dark")
      setTheme(theme)
    })
  }

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        className="flex w-full min-w-0 items-center gap-2 rounded px-2 py-2 text-left text-sm text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-200 dark:hover:bg-gray-800 dark:hover:text-blue-300"
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <UserIcon />
        <span className="min-w-0 flex-1 truncate">{user.email_address}</span>
        <ChevronDownIcon className="rotate-180" />
      </button>
      {open ? (
        <div className="absolute bottom-full left-0 z-30 mb-2 w-60 rounded border border-gray-200 bg-white py-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-950">
          <button
            aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"}
            className="flex w-full items-center gap-2 px-4 py-2 text-left text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={toggleTheme}
            type="button"
          >
            {theme === "dark" ? <SunIcon /> : <MoonIcon />}
            <span>{theme === "dark" ? "Light mode" : "Dark mode"}</span>
          </button>
          <Link className={popupLinkClass()} onClick={onCloseDrawer} to={`${prefix}/profiles/${user.id}`}>Profile</Link>
          <Link className={popupLinkClass()} onClick={onCloseDrawer} to={`${prefix}/profile`}>Settings</Link>
          {showTeamProfile ? <Link className={popupLinkClass()} onClick={onCloseDrawer} to={`${prefix}/profiles/${user.id}`}>My Profile</Link> : null}
          {user.admin ? <Link className="block px-4 py-2 font-medium text-blue-600 hover:bg-gray-50 dark:text-blue-300 dark:hover:bg-gray-800" onClick={onCloseDrawer} to={`${prefix}/admin`}>Admin</Link> : null}
          <div className="my-1 border-t border-gray-100 dark:border-gray-800" />
          <form action="/session" method="post">
            {csrfToken ? <input name="authenticity_token" type="hidden" value={csrfToken} /> : null}
            <input name="_method" type="hidden" value="delete" />
            <button className={popupButtonClass()} type="submit">Sign out</button>
          </form>
        </div>
      ) : null}
    </div>
  )
}

function updateBootstrapTheme(payload: BootstrapPayload | undefined, theme: "light" | "dark") {
  if (!payload?.current_user) return payload

  return {
    ...payload,
    current_user: {
      ...payload.current_user,
      theme
    }
  }
}

function normalizedAppPath(pathname: string) {
  return pathname.replace(/^\/app-shell/, "") || "/"
}

function redirectsToSetup(data: BootstrapPayload | null | undefined, normalizedPath: string) {
  if (!data?.setup || data.setup.complete) return false
  if (data.setup.chat_started) return false
  return normalizedPath === "/" || normalizedPath.startsWith("/dashboard")
}

function isAdminPath(pathname: string) {
  return pathname === "/admin" ||
    pathname.startsWith("/admin/") ||
    pathname === "/invitations" ||
    pathname === "/settings/edit"
}

function isAuthPath(pathname: string) {
  return pathname === "/session/new" ||
    pathname === "/users/new" ||
    pathname === "/passwords/new" ||
    pathname.startsWith("/passwords/")
}

function adminNavItemActive(pathname: string, navPath: string) {
  if (navPath === "/admin") return pathname === navPath

  return pathname === navPath || pathname.startsWith(`${navPath}/`)
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

function activeChatIdFromPath(pathname: string) {
  const match = normalizedAppPath(pathname).match(/^\/chats\/(\d+)(?:\/|$)/)
  return match ? Number(match[1]) : null
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

export function chatSectionsFromPayload(groups: ChatGroupRecord[], loadedSections: Record<string, { chats: ChatNavRecord[]; has_more: boolean }>) {
  return groups.map((group) => {
    const loaded = loadedSections[group.key]
    const seen = new Set<number>()
    const chats = [...group.chats, ...(loaded?.chats || [])]
      .filter((chat) => {
        if (seen.has(chat.id)) return false

        seen.add(chat.id)
        return true
      })
      .sort(compareChatsByLastMessage)
    return {
      key: group.key,
      label: group.label,
      repository_id: group.repository_id,
      chats,
      has_more: loaded?.has_more ?? group.has_more,
      activeAt: Math.max(...chats.map(chatActivityTime))
    }
  })
    .sort((left, right) => right.activeAt - left.activeAt)
    .map(({ activeAt: _activeAt, ...group }) => group)
}

function compareChatsByLastMessage(left: ChatNavRecord, right: ChatNavRecord) {
  if (left.pinned !== right.pinned) return left.pinned ? -1 : 1

  return chatActivityTime(right) - chatActivityTime(left) || right.id - left.id
}

function chatLastMessageTime(chat: ChatNavRecord) {
  return timestampValue(chat.last_message_at)
}

function chatActivityTime(chat: ChatNavRecord) {
  return Math.max(
    chatLastMessageTime(chat),
    timestampValue(chat.updated_at),
    timestampValue(chat.created_at)
  )
}

function timestampValue(value?: string | null) {
  if (!value) return 0

  const timestamp = Date.parse(value)
  return Number.isNaN(timestamp) ? 0 : timestamp
}

function sidebarChatTitle(chat: Pick<ChatNavRecord, "title" | "title_pending">) {
  if (chat.title_pending) return "New chat"
  return chat.title?.trim() || "New chat"
}

function storedSidebarWidth() {
  try {
    return clampSidebarWidth(Number.parseInt(window.localStorage.getItem(SIDEBAR_WIDTH_KEY) || "", 10) || SIDEBAR_DEFAULT_WIDTH)
  } catch (_error) {
    return SIDEBAR_DEFAULT_WIDTH
  }
}

function storeSidebarWidth(width: number) {
  try {
    window.localStorage.setItem(SIDEBAR_WIDTH_KEY, String(width))
  } catch (_error) {
    // Local storage can be unavailable in hardened browser modes; the
    // sidebar still resizes for the current session.
  }
}

function clampSidebarWidth(width: number) {
  return Math.min(Math.max(width, SIDEBAR_MIN_WIDTH), SIDEBAR_MAX_WIDTH)
}

function sidebarLinkClass(active: boolean) {
  return `inline-flex w-full items-center gap-2 rounded px-2.5 py-2 font-medium ${active ? "text-blue-700 dark:text-blue-300 sm:bg-blue-50 dark:sm:bg-blue-900/30" : "text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"}`
}

function recentChatLinkClass(active: boolean) {
  return `flex min-w-0 w-full items-start gap-2 rounded px-2 py-1.5 text-xs ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

function adminSubnavLinkClass(active: boolean) {
  return `block whitespace-nowrap rounded px-3 py-2 font-medium ${active ? "bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"}`
}

function popupLinkClass() {
  return "block px-4 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
}

function popupButtonClass() {
  return "block w-full px-4 py-2 text-left text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-60 dark:text-gray-200 dark:hover:bg-gray-800"
}

export function useTerminalSessionCount(enabled: boolean) {
  const terminalSessions = useQuery({
    queryKey: ["terminal_sessions"],
    queryFn: ({ signal }) => fetchTerminalSessions({ signal }),
    enabled,
    refetchInterval: enabled ? 10000 : false
  })

  if (!enabled) return 0
  return terminalSessions.data?.sessions.filter((session) => !session.finished_at).length ?? 0
}

function PlusIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M12 5v14M5 12h14" stroke="currentColor" strokeLinecap="round" strokeWidth="1.9" />
    </svg>
  )
}

function SearchIcon() {
  return (
    <svg aria-hidden="true" className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-gray-400 dark:text-gray-500" fill="none" viewBox="0 0 24 24">
      <path d="m21 21-4.3-4.3M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function SetupIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M12 4.75 5.25 8.5v7L12 19.25l6.75-3.75v-7L12 4.75Zm0 0v7.5m6.75-3.75L12 12.25 5.25 8.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function DashboardIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M4.75 5.75h6.5v5.5h-6.5v-5.5Zm8 0h6.5v12.5h-6.5V5.75Zm-8 8h6.5v4.5h-6.5v-4.5Z" stroke="currentColor" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function SpendingIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M12 4.75v14.5m3.25-10.5a3 3 0 0 0-3-2h-1a2.5 2.5 0 0 0 0 5h1.5a2.5 2.5 0 0 1 0 5H11a3 3 0 0 1-3-2" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function RepositoryIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M6.75 4.75h8.5L19.25 9v10.25H6.75A2 2 0 0 1 4.75 17V6.75a2 2 0 0 1 2-2Zm8.5 0V9h4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function ScheduleIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M7.75 4v3M16.25 4v3M5.25 8.75h13.5M6.75 5.75h10.5a2 2 0 0 1 2 2v9.5a2 2 0 0 1-2 2H6.75a2 2 0 0 1-2-2v-9.5a2 2 0 0 1 2-2Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function TerminalIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="m5.75 8.25 4 3.75-4 3.75M12.75 16.25h5.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function TeamIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M9.25 11.25a3 3 0 1 0 0-6 3 3 0 0 0 0 6Zm-5 8a5 5 0 0 1 10 0m1.25-8.5a2.5 2.5 0 1 0 0-5m.75 13.5h3.5a4.25 4.25 0 0 0-4.25-4.25" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}

function UserIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM4.75 20.25a7.25 7.25 0 0 1 14.5 0" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function ChevronDownIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={`h-3 w-3 shrink-0 ${className}`} fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M5.23 7.21a.75.75 0 0 1 1.06.02L10 11.17l3.71-3.94a.75.75 0 1 1 1.08 1.04l-4.25 4.5a.75.75 0 0 1-1.08 0l-4.25-4.5a.75.75 0 0 1 .02-1.06Z" fillRule="evenodd" />
    </svg>
  )
}

function MoonIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M21 14.25A8.25 8.25 0 0 1 9.75 3a8.25 8.25 0 1 0 11.25 11.25Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function SunIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24">
      <path d="M12 4.75V3m0 18v-1.75M4.75 12H3m18 0h-1.75M6.87 6.87 5.64 5.64m12.72 12.72-1.23-1.23m0-10.26 1.23-1.23M5.64 18.36l1.23-1.23M15.25 12a3.25 3.25 0 1 1-6.5 0 3.25 3.25 0 0 1 6.5 0Z" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.9" />
    </svg>
  )
}

function HideIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M4.75 7.75h14.5M9.75 7.75V5.5h4.5v2.25m-7.5 0 .75 11h9l.75-11M10.5 11v4.5m3-4.5v4.5" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.7" />
    </svg>
  )
}
