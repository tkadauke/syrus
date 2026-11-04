import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { ACTIVITY_MOBILE_QUERY, useMediaQuery } from "../../hooks/useMediaQuery"
import { dismissTopLayer } from "../../lib/dismissLayers"
import { ActivityContext, type ActivityOpenOptions, type ActivityTab } from "./ActivityContext"
import { ActivityShell } from "./ActivityShell"

/**
 * Owns the single mobile Activity overlay. Opening while already open only switches the tab, so overlays never stack.
 *
 * Back is deterministic: the topmost registered nested layer (e.g. Customize) closes first, then Activity itself.
 * Activity owns exactly one synthetic history entry. It is consumed by closing, and by leaving Activity for another
 * route (history.back() first, then the navigation), so no dead overlay entry is left under the destination.
 */
export function ActivityProvider({ children, prefix = "" }: { children: ReactNode; prefix?: string }) {
  const isMobile = useMediaQuery(ACTIVITY_MOBILE_QUERY)
  const navigate = useNavigate()
  const location = useLocation()
  const [state, setState] = useState<{ open: boolean; tab: ActivityTab }>({ open: false, tab: "notifications" })
  const invokerRef = useRef<HTMLElement | null>(null)
  const onNavigateRef = useRef<(() => void) | undefined>(undefined)
  const pendingNavigationRef = useRef<string | null>(null)
  const historyEntryRef = useRef(false)
  const openRef = useRef(false)
  openRef.current = state.open
  const routeKey = `${location.pathname}${location.search}`
  const openedAtRoute = useRef(routeKey)

  const finish = useCallback((restoreFocus = true) => {
    const invoker = invokerRef.current
    invokerRef.current = null
    openRef.current = false
    setState((current) => ({ ...current, open: false }))
    if (restoreFocus && invoker) requestAnimationFrame(() => invoker.isConnected && invoker.focus())
  }, [])

  const closeActivity = useCallback(() => {
    if (!openRef.current) return
    // The popstate handler performs the actual close so the browser stack and UI stay in sync.
    if (historyEntryRef.current) window.history.back()
    else finish()
  }, [finish])

  const openActivity = useCallback((tab: ActivityTab, options: ActivityOpenOptions = {}) => {
    if (openRef.current) {
      setState((current) => ({ ...current, tab }))
      return
    }
    invokerRef.current = options.invoker ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null)
    onNavigateRef.current = options.onNavigate
    openedAtRoute.current = `${window.location.pathname}${window.location.search}`
    window.history.pushState({ ...(window.history.state ?? {}), syrusActivity: true }, "")
    historyEntryRef.current = true
    openRef.current = true
    setState({ open: true, tab })
  }, [])

  const selectTab = useCallback((tab: ActivityTab) => setState((current) => ({ ...current, tab })), [])

  const navigateFromActivity = useCallback(
    (to: string) => {
      onNavigateRef.current?.()
      if (historyEntryRef.current) {
        // Pop our entry first; the navigation happens once the browser has settled on the underlying page.
        pendingNavigationRef.current = to
        window.history.back()
      } else {
        finish(false)
        navigate(to)
      }
    },
    [finish, navigate]
  )

  useEffect(() => {
    if (!state.open) return

    function onPopState() {
      const pending = pendingNavigationRef.current
      if (pending == null && dismissTopLayer()) {
        // The pop consumed Activity's entry while a nested layer was still open: close the layer, restore the entry.
        window.history.pushState({ ...(window.history.state ?? {}), syrusActivity: true }, "")
        return
      }
      historyEntryRef.current = false
      pendingNavigationRef.current = null
      finish(pending == null)
      if (pending != null) navigate(pending)
    }

    window.addEventListener("popstate", onPopState)
    return () => window.removeEventListener("popstate", onPopState)
  }, [state.open, finish, navigate])

  // A route change we did not initiate (e.g. an in-card link) dismisses Activity so it never covers the new page.
  useEffect(() => {
    if (openRef.current && routeKey !== openedAtRoute.current && pendingNavigationRef.current == null) {
      historyEntryRef.current = false
      finish(false)
    }
  }, [routeKey, finish])

  // Rotating or resizing to a desktop width hands off to the popover/drawer: close Activity.
  useEffect(() => {
    if (!isMobile && state.open) closeActivity()
  }, [isMobile, state.open, closeActivity])

  const value = useMemo(
    () => ({ isMobile, open: state.open, tab: state.tab, openActivity, closeActivity, selectTab }),
    [isMobile, state.open, state.tab, openActivity, closeActivity, selectTab]
  )

  return (
    <ActivityContext.Provider value={value}>
      {children}
      {state.open && isMobile ? (
        <ActivityShell navigateTo={navigateFromActivity} onClose={closeActivity} onSelectTab={selectTab} prefix={prefix} tab={state.tab} />
      ) : null}
    </ActivityContext.Provider>
  )
}
