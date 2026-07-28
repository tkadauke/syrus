import { PUBLILIUS_SYRUS_QUOTES } from "./appChromeV2/quotes"
import { ChevronDownIcon, DashboardIcon, MoonIcon, PlusIcon, RepositoryIcon, ScheduleIcon, SearchIcon, SetupIcon, SpendingIcon, SunIcon, TeamIcon, TerminalIcon, UserIcon } from "./appChromeV2/icons"
import { SIDEBAR_MAX_WIDTH, SIDEBAR_MIN_WIDTH, adminNavItemActive, adminSubnavLinkClass, bugReportContext, clampSidebarWidth, isAdminPath, isAuthPath, normalizedAppPath, popupButtonClass, popupLinkClass, redirectsToSetup, sidebarLinkClass, storeSidebarWidth, storedSidebarWidth, updateBootstrapTheme, withRoutePrefix } from "./appChromeV2/helpers"
import { RecentChatsSidebar } from "./appChromeV2/RecentChatsSidebar"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { BRAND_ICON_SRC } from "../lib/brandIcon"
import { type FormEvent, type KeyboardEvent, type MouseEvent, type ReactNode, useEffect, useMemo, useRef, useState } from "react"
import { useTranslation } from "react-i18next"
import { Link, Navigate, Outlet, useLocation, useNavigate } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { createEmptyChat, fetchNewChat, type ChatsIndexPayload } from "../api/chats"
import { patchJson } from "../api/client"
import { dashboardApiSearch, fetchDashboardChrome, type DashboardChromePayload, type DashboardSubject } from "../api/dashboard"
import { fetchTerminalSessions } from "../api/terminal"
import { BugReportButton } from "../components/BugReportButton"
import { BuildBadge } from "../components/BuildBadge"
import { CloseIcon } from "../components/CloseIcon"
import { DashboardSmartFolderNav } from "../components/DashboardSmartFolderNav"
import { NoticeToast } from "../components/NoticeToast"
import { NotificationsBell } from "../components/Notifications"
import { ShellNotices } from "../components/ShellNotices"
import { SyrusBrand } from "../components/SyrusBrand"
import { TestChannelBadge, TestChannelDot } from "../components/TestChannelBadge"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { updateRecentChatCache } from "../lib/chatCache"
import { firstUnstartedChat } from "../lib/unstartedChat"

export const PUBLILIUS_SYRUS_WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Publilius_Syrus"

function randomPubliliusSyrusQuote() {
  return PUBLILIUS_SYRUS_QUOTES[Math.floor(Math.random() * PUBLILIUS_SYRUS_QUOTES.length)]
}

export function AppChromeV2({ children, initialBootstrap }: { children?: ReactNode; initialBootstrap: BootstrapPayload | null }) {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { t } = useTranslation(["nav", "chat"])
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
  const showDashboardSidebarSubjects = true
  const quote = useMemo(randomPubliliusSyrusQuote, [])
  const showQuote = !normalizedPath.startsWith("/chats") && !normalizedPath.startsWith("/terminal")
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
  const navItems: Array<{ id: string; label: string; to: string; active: boolean; icon: ReactNode; badge?: number }> = user ? [
    ...(inOnboarding ? [{ id: "setup", label: t("nav:setup"), to: `${prefix}/onboarding`, active: normalizedPath === "/onboarding", icon: <SetupIcon /> }] : []),
    ...(tabsHidden ? [] : [
      { id: "dashboard", label: t("nav:dashboard"), to: `${prefix}/dashboard/jobs`, active: normalizedPath === "/" || normalizedPath.startsWith("/dashboard"), icon: <DashboardIcon /> },
      { id: "spending", label: t("nav:spending"), to: `${prefix}/insights/spending`, active: normalizedPath.startsWith("/insights/spending"), icon: <SpendingIcon /> },
      { id: "repositories", label: t("nav:repositories"), to: `${prefix}/repositories`, active: normalizedPath.startsWith("/repositories"), icon: <RepositoryIcon /> },
      { id: "schedules", label: t("nav:schedules"), to: `${prefix}/scheduled_tasks`, active: normalizedPath === "/scheduled_tasks" || normalizedPath.startsWith("/scheduled_tasks/"), icon: <ScheduleIcon /> },
      ...(data?.feature_flags?.terminal ? [{
        id: "terminal",
        label: t("nav:terminal"),
        to: `${prefix}/terminal`,
        active: normalizedPath.startsWith("/terminal"),
        icon: <TerminalIcon />,
        badge: terminalSessionCount
      }] : []),
      ...(data && data.team_user_count > 1 ? [{ id: "team", label: t("nav:team"), to: `${prefix}/profiles`, active: normalizedPath.startsWith("/profiles"), icon: <TeamIcon /> }] : [])
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
      const newChat = await fetchNewChat()
      const created = await createEmptyChat(newChat.default_repository_id)
      updateRecentChatCache(queryClient, created.chat, { prepend: true })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    } catch (_error) {
      setNotice(t("chat:unable_to_start"))
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
    <div className="flex h-[100dvh] overflow-hidden bg-gray-50 text-gray-900 dark:bg-gray-900 dark:text-white">
      <aside className="relative hidden shrink-0 lg:flex" style={{ width: `${sidebarWidth}px` }}>
        <SidebarContent
          csrfToken={data?.csrf_token}
          dashboardSubnavEnabled={true}
          featureFlags={data?.feature_flags ?? {}}
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
          aria-label={t("nav:resize_sidebar")}
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
            aria-label={t("nav:open_sidebar")}
            className="fixed left-3 top-3 z-30 inline-flex h-11 w-11 items-center justify-center rounded border border-gray-200 bg-white text-gray-900 shadow-lg hover:bg-gray-50 hover:text-blue-600 dark:border-gray-800 dark:bg-gray-950 dark:text-white dark:hover:bg-gray-900 dark:hover:text-blue-300 lg:hidden"
            onClick={() => setDrawerOpen(true)}
            type="button"
          >
            <img alt="" aria-hidden="true" className="h-6 w-6 rounded" src={BRAND_ICON_SRC} />
            {/* The in-flow top-bar TEST badge scrolls away with the bar on
                mobile; keep the floating trigger distinguishable from a
                side-by-side production build with an amber corner dot. */}
            <TestChannelDot />
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
            featureFlags={data?.feature_flags ?? {}}
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
          <div className="flex min-w-0 items-center gap-2">
            <button
              aria-label={t("nav:open_sidebar")}
              className="inline-flex min-h-[44px] min-w-0 items-center text-lg font-semibold text-gray-900 hover:text-blue-600 dark:text-white dark:hover:text-blue-300"
              onClick={() => setDrawerOpen(true)}
              type="button"
            >
              <SyrusBrand />
            </button>
            <TestChannelBadge />
          </div>
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
      {user ? <BugReportButton bugReportMode={data?.app?.bug_report_mode ?? null} context={bugReportContext(location.pathname)} position="bottom-right" reportIssueRepoSlug={data?.app?.report_issue_repo_slug ?? null} /> : null}
      <BuildBadge builtAt={data?.app?.built_at} revision={data?.app?.revision} version={data?.app?.version} />
    </div>
  )
}

function PubliliusSyrusFooter({ quote }: { quote: { latin: string; english: string } }) {
  return (
    <footer className="hidden lg:block py-4 text-center text-xs text-gray-400">
      <a href={PUBLILIUS_SYRUS_WIKIPEDIA_URL} rel="noopener" target="_blank" title={quote.english}>
        {quote.latin}
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
  const { t } = useTranslation("nav")
  const active = alerts || []
  if (active.length === 0) return null

  return (
    <section aria-label={t("nav:system_alerts_aria")} className="mx-auto max-w-[96rem] space-y-3 px-6 pt-4">
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

function AdminSubnav({ featureFlags, normalizedPath, prefix }: { featureFlags: Record<string, boolean>; normalizedPath: string; prefix: string }) {
  const { t } = useTranslation("admin")
  const adminNavItems = [
    { label: t("admin:nav_overview"), to: "/admin", paths: ["/admin"] },
    { label: t("admin:nav_queue"), to: "/admin/queue", paths: ["/admin/queue"] },
    { label: t("admin:nav_stuck"), to: "/admin/stuck", paths: ["/admin/stuck"] },
    { label: t("admin:nav_processes"), to: "/admin/processes", paths: ["/admin/processes"] },
    { label: t("admin:nav_users"), to: "/admin/users", paths: ["/admin/users"] },
    { label: t("admin:nav_console"), to: "/admin/console", paths: ["/admin/console"] },
    { label: t("admin:nav_installations"), to: "/admin/installations", paths: ["/admin/installations"] },
    { label: t("admin:nav_github_app"), to: "/admin/github_app/register", paths: ["/admin/github_app"] },
    { label: t("admin:nav_invitations"), to: "/invitations", paths: ["/invitations"] },
    { label: t("admin:nav_settings"), to: "/settings/edit", paths: ["/settings/edit"] }
  ]
  const items = [
    ...adminNavItems.slice(0, -1),
    ...(hasFeatureFlags(featureFlags) ? [{ label: t("admin:nav_features"), to: "/admin/features", paths: ["/admin/features"] }] : []),
    adminNavItems[adminNavItems.length - 1]
  ]

  return (
    <div className="border-b border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <nav aria-label={t("nav:admin_nav_aria")} title="Curia — The Roman Senate house" className="flex gap-2 overflow-x-auto px-4 py-3 text-sm">
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
  featureFlags,
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
  featureFlags: Record<string, boolean>
  navItems: Array<{ id: string; label: string; to: string; active: boolean; icon: ReactNode; badge?: number }>
  onCloseDrawer: () => void
  onNotice: (message: string | null) => void
  onStartChat: () => void
  prefix: string
  showDashboardSidebarSubjects: boolean
  showTeamProfile: boolean
  user: BootstrapPayload["current_user"] | undefined
}) {
  const { t } = useTranslation("nav")
  const dashboardActive = navItems.some((item) => item.id === "dashboard" && item.active)
  const [dashboardNavOpen, setDashboardNavOpen] = useState(dashboardActive)

  useEffect(() => {
    setDashboardNavOpen(dashboardActive)
  }, [dashboardActive])

  function handlePrimaryNavClick(item: { id: string; active: boolean }, event: MouseEvent<HTMLAnchorElement>) {
    if (item.id === "dashboard" && dashboardSubnavEnabled) {
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
          <div className="flex min-w-0 items-center gap-2">
            <Link className="text-lg font-semibold text-gray-900 dark:text-white" onClick={onCloseDrawer} to={prefix || "/"}><SyrusBrand /></Link>
            <TestChannelBadge />
          </div>
          <div className="flex items-center gap-1">
            {user ? <NotificationsBell initialUnreadCount={user.notification_unread_count ?? 0} onNavigate={onCloseDrawer} prefix={prefix} /> : null}
            <button
              aria-label={t("nav:close_sidebar")}
              className="inline-flex h-11 w-11 items-center justify-center rounded text-gray-700 hover:bg-gray-100 hover:text-blue-600 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300 lg:hidden"
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
            <span>{t("nav:new_chat")}</span>
          </button>
          <SidebarSearchForm onCloseDrawer={onCloseDrawer} prefix={prefix} />
        </div>
        <div className="px-3 pb-4">
          <nav aria-label={t("nav:primary_nav_aria")} className="flex flex-col gap-1 text-sm">
            {navItems.map((item) => {
              const link = (
                <Link className={sidebarLinkClass(item.active)} key={item.id} onClick={(event) => handlePrimaryNavClick(item, event)} to={item.to}>
                  {item.icon}
                  <span>{item.label}</span>
                  {item.badge ? <span className="ml-auto rounded-full bg-red-500 px-1.5 py-0.5 text-xs leading-none text-white">{item.badge}</span> : null}
                </Link>
              )

              if (item.id !== "dashboard") return link

              return (
                <div key={item.id}>
                  {link}
                  {dashboardSubnavEnabled ? (
                    <SidebarDashboardNav expanded={dashboardNavOpen} onCloseDrawer={onCloseDrawer} prefix={prefix} showSubjects={showDashboardSidebarSubjects} />
                  ) : null}
                </div>
              )
            })}
          </nav>
        </div>
        <RecentChatsSidebar featureFlags={featureFlags} onCloseDrawer={onCloseDrawer} onNotice={onNotice} prefix={prefix} userPresent={Boolean(user)} />
      </div>
      <ShellNotices />
      <div className="shrink-0 border-t border-gray-200 p-3 dark:border-gray-800">
        {user ? (
          <nav aria-label={t("account_aria")}>
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
  const { t } = useTranslation("nav")
  const inputRef = useRef<HTMLInputElement | null>(null)
  const [query, setQuery] = useState(() => searchQueryFromLocation(location.search, location.pathname))
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
    setQuery(searchQueryFromLocation(location.search, location.pathname))
  }, [location.search, location.pathname])

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
      <label className="sr-only" htmlFor="sidebar-global-search">{t("nav:search_label")}</label>
      <SearchIcon />
      <input
        className="block h-9 w-full rounded border border-gray-200 bg-gray-50 py-1.5 pl-9 pr-3 text-sm text-gray-900 placeholder:text-gray-400 focus:border-blue-500 focus:bg-white focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500 dark:focus:border-blue-400 dark:focus:bg-gray-950 dark:focus:ring-blue-400"
        id="sidebar-global-search"
        onChange={(event) => {
          userEditedRef.current = true
          setQuery(event.target.value)
        }}
        placeholder={t("nav:search_placeholder")}
        ref={inputRef}
        type="search"
        value={query}
      />
    </form>
  )
}

function searchQueryFromLocation(search: string, pathname: string) {
  if (!pathname.includes("/search")) return ""
  return new URLSearchParams(search).get("q") || ""
}

function SidebarDashboardNav({ expanded, onCloseDrawer, prefix, showSubjects }: { expanded: boolean; onCloseDrawer: () => void; prefix: string; showSubjects: boolean }) {
  const location = useLocation()
  const isDashboard = location.pathname.includes("/dashboard")
  const search = dashboardApiSearch(location.pathname, location.search)
  const [renderedPayload, setRenderedPayload] = useState<DashboardChromePayload | null>(null)
  const dashboard = useQuery({
    queryKey: ["dashboard", "chrome", search],
    queryFn: ({ signal }) => fetchDashboardChrome(search, { signal }),
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
      className={`grid overflow-hidden transition-[grid-template-rows,margin-top] duration-200 ease-out ${expanded ? "grid-rows-[1fr] mt-1" : "grid-rows-[0fr]"}`}
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

function SidebarDashboardSubjects({ onCloseDrawer, payload, prefix }: { onCloseDrawer: () => void; payload: DashboardChromePayload; prefix: string }) {
  const { t } = useTranslation(["epics", "jobs", "common"])
  const subjects: Array<{ key: DashboardSubject; label: string; path: string }> = [
    { key: "epic", label: t("epics:title"), path: "/dashboard/epics" },
    { key: "job", label: t("jobs:title"), path: "/dashboard/jobs" },
    { key: "workflow", label: t("common:workflows"), path: "/dashboard/workflows" }
  ]

  return (
    <nav aria-label={t("nav:dashboard_sections_aria")} className="inline-flex max-w-full flex-wrap overflow-hidden rounded border border-gray-300 bg-white text-xs dark:border-gray-700 dark:bg-gray-900">
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

function SettingsPopup({ csrfToken, onCloseDrawer, prefix, showTeamProfile, user }: {
  csrfToken?: string
  onCloseDrawer: () => void
  prefix: string
  showTeamProfile: boolean
  user: NonNullable<BootstrapPayload["current_user"]>
}) {
  const queryClient = useQueryClient()
  const { t } = useTranslation("nav")
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
            aria-label={theme === "dark" ? t("nav:switch_to_light_mode") : t("nav:switch_to_dark_mode")}
            className="flex w-full items-center gap-2 px-4 py-2 text-left text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
            onClick={toggleTheme}
            type="button"
          >
            {theme === "dark" ? <SunIcon /> : <MoonIcon />}
            <span>{theme === "dark" ? t("nav:light_mode") : t("nav:dark_mode")}</span>
          </button>
          <Link className={popupLinkClass()} onClick={onCloseDrawer} to={`${prefix}/profiles/${user.id}`}>{t("nav:profile")}</Link>
          <Link className={popupLinkClass()} onClick={onCloseDrawer} to={`${prefix}/profile`}>{t("nav:settings")}</Link>
          {user.admin ? <Link className="block px-4 py-2 font-medium text-blue-600 hover:bg-gray-50 dark:text-blue-300 dark:hover:bg-gray-800" onClick={onCloseDrawer} title="Curia — The Roman Senate house" to={`${prefix}/admin`}>{t("nav:admin")}</Link> : null}
          <div className="my-1 border-t border-gray-100 dark:border-gray-800" />
          <form action="/session" method="post">
            {csrfToken ? <input name="authenticity_token" type="hidden" value={csrfToken} /> : null}
            <input name="_method" type="hidden" value="delete" />
            <button className={popupButtonClass()} type="submit">{t("nav:sign_out")}</button>
          </form>
        </div>
      ) : null}
    </div>
  )
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

