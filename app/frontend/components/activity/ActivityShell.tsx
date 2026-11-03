import { useEffect, useLayoutEffect, useRef, type KeyboardEvent as ReactKeyboardEvent } from "react"
import { createPortal } from "react-dom"
import { useT } from "../../hooks/useT"
import { hasDismissLayers } from "../../lib/dismissLayers"
import { NotificationsActivityPanel, useNotificationsQuery } from "../Notifications"
import type { ActivityTab } from "./ActivityContext"
import { ApprovalsActivityPanel } from "./ApprovalsActivityPanel"
import { usePendingApprovals } from "./usePendingApprovals"

const SHELL_CLASS = [
  "fixed inset-0 z-50 flex h-[100dvh] max-h-[100dvh] w-screen flex-col overflow-hidden",
  "bg-surface text-text-primary motion-safe:transition-opacity"
].join(" ")
const TABS: ActivityTab[] = ["notifications", "approvals"]
const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'

function badgeText(count: number) {
  return count > 9 ? "9+" : String(count)
}

/**
 * Full-screen mobile surface shared by the notification inbox and the approval inbox.
 * Both panels stay mounted so each keeps its own scroll position and expanded-card state;
 * only the selected one is visible.
 */
export function ActivityShell({
  onClose,
  navigateTo,
  onSelectTab,
  prefix,
  tab
}: {
  onClose: () => void
  navigateTo: (to: string) => void
  onSelectTab: (tab: ActivityTab) => void
  prefix: string
  tab: ActivityTab
}) {
  const { t } = useT("nav")
  const rootRef = useRef<HTMLDivElement>(null)
  const scrollRefs = useRef<Record<ActivityTab, HTMLDivElement | null>>({ notifications: null, approvals: null })
  const savedScroll = useRef<Record<ActivityTab, number>>({ notifications: 0, approvals: 0 })
  const tabRefs = useRef<Record<ActivityTab, HTMLButtonElement | null>>({ notifications: null, approvals: null })
  const notifications = useNotificationsQuery({ enabled: true })
  const { pendingCount } = usePendingApprovals()
  const counts: Record<ActivityTab, number> = { notifications: notifications.data?.unread_count ?? 0, approvals: pendingCount }
  const onCloseRef = useRef(onClose)
  onCloseRef.current = onClose

  // Lock background scroll while Activity is open.
  useEffect(() => {
    const previous = document.body.style.overflow
    document.body.style.overflow = "hidden"
    return () => {
      document.body.style.overflow = previous
    }
  }, [])

  // Keep the page behind the shell out of the tab order and accessibility tree. A mutation observer also
  // isolates layers portaled later; nested dialogs (Customize) and live regions stay interactive/announced.
  useEffect(() => {
    const isolated = new Set<HTMLElement>()
    const isolate = (node: Node) => {
      if (!(node instanceof HTMLElement) || node === rootRef.current || isolated.has(node)) return
      if (node.matches('[role="status"], [role="alert"], [aria-live]') || node.querySelector('[aria-modal="true"], [aria-live]')) return
      if (node.hasAttribute("inert")) return
      node.setAttribute("inert", "")
      isolated.add(node)
    }
    Array.from(document.body.children).forEach(isolate)
    const observer = new MutationObserver((records) => records.forEach((record) => record.addedNodes.forEach(isolate)))
    observer.observe(document.body, { childList: true })
    return () => {
      observer.disconnect()
      isolated.forEach((node) => node.removeAttribute("inert"))
    }
  }, [])

  // Initial focus: the selected tab, so the dialog is announced with its context.
  useEffect(() => {
    tabRefs.current[tab]?.focus()
  }, [])

  // Restore the selected panel's own scroll position after a tab switch.
  useLayoutEffect(() => {
    const element = scrollRefs.current[tab]
    if (element) element.scrollTop = savedScroll.current[tab]
  }, [tab])

  function select(next: ActivityTab) {
    if (next === tab) return
    const current = scrollRefs.current[tab]
    if (current) savedScroll.current[tab] = current.scrollTop
    onSelectTab(next)
  }

  // Escape closes Activity unless a nested layer (e.g. Customize) is open; that layer handles its own Escape first.
  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape" || event.defaultPrevented || hasDismissLayers()) return
      onCloseRef.current()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [])

  function onRootKeyDown(event: ReactKeyboardEvent<HTMLDivElement>) {
    if (event.key !== "Tab" || hasDismissLayers()) return
    const focusable = Array.from(rootRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR) ?? []).filter((node) => !node.closest("[hidden]"))
    if (focusable.length === 0) return
    const first = focusable[0]
    const last = focusable[focusable.length - 1]
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault()
      first.focus()
    }
  }

  function onTabKeyDown(event: ReactKeyboardEvent<HTMLButtonElement>, index: number) {
    let next: number | null = null
    if (event.key === "ArrowRight") next = (index + 1) % TABS.length
    else if (event.key === "ArrowLeft") next = (index - 1 + TABS.length) % TABS.length
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = TABS.length - 1
    if (next == null) return
    event.preventDefault()
    select(TABS[next])
    tabRefs.current[TABS[next]]?.focus()
  }

  return createPortal(
    <div
      aria-labelledby="activity-shell-title"
      aria-modal="true"
      className={SHELL_CLASS}
      data-testid="activity-shell"
      onKeyDown={onRootKeyDown}
      ref={rootRef}
      role="dialog"
      style={{
        paddingTop: "env(safe-area-inset-top)",
        paddingBottom: "env(safe-area-inset-bottom)",
        paddingLeft: "env(safe-area-inset-left)",
        paddingRight: "env(safe-area-inset-right)"
      }}
    >
      <header className="shrink-0 border-b border-border px-4 pb-3 pt-3">
        <div className="flex items-center gap-3">
          <button
            aria-label={t("activity.close")}
            className="inline-flex h-9 w-9 items-center justify-center rounded text-text-secondary hover:bg-surface-subtle"
            onClick={onClose}
            type="button"
          >
            <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
              <path d="M15.25 5.75 9 12l6.25 6.25" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
            </svg>
          </button>
          <h2 className="text-lg font-semibold" id="activity-shell-title">
            {t("activity.title")}
          </h2>
        </div>
        <div aria-label={t("activity.tabs")} className="mt-3 grid grid-cols-2 gap-1 rounded-lg bg-surface-subtle p-1" role="tablist">
          {TABS.map((key, index) => {
            const selected = key === tab
            return (
              <button
                aria-controls={`activity-panel-${key}`}
                aria-selected={selected}
                className={`flex min-h-9 items-center justify-center gap-2 rounded-md px-3 text-sm font-medium ${selected ? "bg-surface text-text-primary shadow-sm" : "text-text-secondary"}`}
                id={`activity-tab-${key}`}
                key={key}
                onClick={() => select(key)}
                onKeyDown={(event) => onTabKeyDown(event, index)}
                ref={(node) => {
                  tabRefs.current[key] = node
                }}
                role="tab"
                tabIndex={selected ? 0 : -1}
                type="button"
              >
                <span>{t(`activity.tab_${key}`)}</span>
                {counts[key] > 0 ? (
                  <span
                    aria-label={t(`activity.count_${key}`, { count: counts[key] })}
                    className="min-w-5 rounded-full bg-brand px-1.5 py-0.5 text-center text-2xs font-semibold leading-none text-on-brand"
                    data-testid={`activity-count-${key}`}
                  >
                    {badgeText(counts[key])}
                  </span>
                ) : null}
              </button>
            )
          })}
        </div>
      </header>
      {TABS.map((key) => (
        <div
          aria-labelledby={`activity-tab-${key}`}
          className="min-h-0 flex-1 overflow-y-auto overscroll-contain"
          hidden={key !== tab}
          id={`activity-panel-${key}`}
          key={key}
          ref={(node) => {
            scrollRefs.current[key] = node
          }}
          role="tabpanel"
        >
          {key === "notifications" ? (
            <NotificationsActivityPanel navigateTo={navigateTo} prefix={prefix} />
          ) : (
            <ApprovalsActivityPanel navigateTo={navigateTo} prefix={prefix} />
          )}
        </div>
      ))}
    </div>,
    document.body
  )
}
