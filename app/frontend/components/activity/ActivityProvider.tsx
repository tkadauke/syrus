import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { ACTIVITY_MOBILE_QUERY, useMediaQuery } from "../../hooks/useMediaQuery"
import { ActivityContext, type ActivityOpenOptions, type ActivityTab } from "./ActivityContext"
import { ActivityShell } from "./ActivityShell"

/**
 * Owns the single mobile Activity overlay. Opening while already open only switches the tab, so overlays never stack.
 * Back handling is deterministic: a nested dialog (e.g. Customize) closes first, then Activity itself.
 * Activity pushes exactly one history entry and consumes it on close.
 */
export function ActivityProvider({ children, prefix = "" }: { children: ReactNode; prefix?: string }) {
  const isMobile = useMediaQuery(ACTIVITY_MOBILE_QUERY)
  const [state, setState] = useState<{ open: boolean; tab: ActivityTab }>({ open: false, tab: "notifications" })
  const invokerRef = useRef<HTMLElement | null>(null)
  const onNavigateRef = useRef<(() => void) | undefined>(undefined)
  const historyEntryRef = useRef(false)
  const openRef = useRef(false)
  openRef.current = state.open

  const finish = useCallback(() => {
    const invoker = invokerRef.current
    invokerRef.current = null
    setState((current) => ({ ...current, open: false }))
    if (invoker) requestAnimationFrame(() => invoker.isConnected && invoker.focus())
  }, [])

  const closeActivity = useCallback(() => {
    if (!openRef.current) return
    if (historyEntryRef.current) {
      // popstate handler performs the actual close so the browser stack and UI stay in sync.
      window.history.back()
    } else {
      finish()
    }
  }, [finish])

  const openActivity = useCallback((tab: ActivityTab, options: ActivityOpenOptions = {}) => {
    if (openRef.current) {
      setState((current) => ({ ...current, tab }))
      return
    }
    invokerRef.current = options.invoker ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null)
    onNavigateRef.current = options.onNavigate
    window.history.pushState({ ...(window.history.state ?? {}), syrusActivity: true }, "")
    historyEntryRef.current = true
    openRef.current = true
    setState({ open: true, tab })
  }, [])

  const selectTab = useCallback((tab: ActivityTab) => setState((current) => ({ ...current, tab })), [])

  useEffect(() => {
    if (!state.open) return

    function onPopState() {
      const nested = Array.from(document.querySelectorAll('[aria-modal="true"]')).filter((node) => node.getAttribute("data-testid") !== "activity-shell")
      if (nested.length > 0) {
        // Back closes the nested layer first; restore Activity's history entry.
        document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }))
        window.history.pushState({ ...(window.history.state ?? {}), syrusActivity: true }, "")
        return
      }
      historyEntryRef.current = false
      finish()
    }

    window.addEventListener("popstate", onPopState)
    return () => window.removeEventListener("popstate", onPopState)
  }, [state.open, finish])

  // Rotating or resizing to a desktop width hands off to the popover/drawer: close Activity.
  useEffect(() => {
    if (!isMobile && state.open) closeActivity()
  }, [isMobile, state.open, closeActivity])

  // Leaving via an in-app link must not leave a dead history entry marker behind.
  const navigateAway = useCallback(() => {
    onNavigateRef.current?.()
    historyEntryRef.current = false
    invokerRef.current = null
    setState((current) => ({ ...current, open: false }))
  }, [])

  const value = useMemo(
    () => ({ isMobile, open: state.open, tab: state.tab, openActivity, closeActivity, selectTab }),
    [isMobile, state.open, state.tab, openActivity, closeActivity, selectTab]
  )

  return (
    <ActivityContext.Provider value={value}>
      {children}
      {state.open && isMobile ? (
        <ActivityShell onClose={closeActivity} onNavigate={navigateAway} onSelectTab={selectTab} prefix={prefix} tab={state.tab} />
      ) : null}
    </ActivityContext.Provider>
  )
}
