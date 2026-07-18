import { useEffect, useRef, useState, type ReactNode } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { exchangeClaudeOauth, startClaudeOauth, testClaudeCli, type CredentialTestResult } from "../../api/credentials"
import { openInNewTab } from "../../lib/desktopShell"
import { useT } from "../../hooks/useT"
import { useBackendOutage } from "../../hooks/useBackendUpdate"

type Preflight =
  | { status: "checking" }
  | { status: "done"; result: CredentialTestResult }
  | { status: "error" }

// The Claude subscription connect flow: a CLI preflight on mount ("Claude
// already works on this machine"), authorize with a popup-blocked fallback,
// and paste-to-connect auto-exchange. Extracted from ConfigureAgentModal so
// onboarding and the credentials page share the identical experience.
//
// The preflight POSTs test_claude_cli, which spawns `claude --print`
// server-side (30s timeout) — hosts must only mount this component behind an
// explicit user action (a modal CTA, a card's Connect/Replace click), never
// on a plain page view.
//
// Backend-outage aware: while the desktop shell's backend update has the
// containers down, the preflight is deferred (a rejected check would
// silently drop the "Claude already works" confirmation and walk the user
// through re-authorizing credentials that sit safely in the DB) and the
// authorize walkthrough is replaced with the shared updating note. When the
// outage clears, the preflight fires automatically (backendOutage is a
// dependency of the effect — outage-state changes, not visibility changes,
// are what re-run it, so hosts that keep this component mounted-hidden
// never double-fire the check).
//
// The exchange saves + tests the token server-side; on success the
// bootstrap + credentials queries are invalidated before onConnected fires.
export function ClaudeConnect({
  onConnected,
  onPreflight,
  secondaryAction,
  autoFocus = false
}: {
  onConnected: (result: CredentialTestResult) => void
  onPreflight?: (ready: boolean) => void
  secondaryAction?: ReactNode
  autoFocus?: boolean
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [preflight, setPreflight] = useState<Preflight>({ status: "checking" })
  const [authStarted, setAuthStarted] = useState(false)
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const [code, setCode] = useState("")
  const [exchanging, setExchanging] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const backendOutage = useBackendOutage()
  const authorizeRef = useRef<HTMLButtonElement>(null)

  // When the host reveals this flow via an explicit click that unmounted the
  // clicked control (e.g. a card's Replace button), move keyboard focus to
  // the flow's first actionable control. During an outage the walkthrough
  // (and its authorize button) is replaced by the updating note, so this
  // re-runs when the outage clears and the button mounts.
  useEffect(() => {
    if (autoFocus && !backendOutage) authorizeRef.current?.focus()
  }, [autoFocus, backendOutage])

  // Preflight: is Claude already usable on this machine? Deferred while the
  // backend outage is on — the call could only fail — and retried
  // automatically when the outage clears (backendOutage is a dependency).
  useEffect(() => {
    if (backendOutage) return

    let cancelled = false
    setPreflight({ status: "checking" })
    testClaudeCli()
      .then((payload) => {
        if (cancelled) return
        setPreflight({ status: "done", result: payload.credential_test })
        onPreflight?.(payload.credential_test.ok)
      })
      .catch(() => {
        if (cancelled) return
        setPreflight({ status: "error" })
        onPreflight?.(false)
      })
    return () => {
      cancelled = true
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- re-run only on outage transitions
  }, [backendOutage])

  async function authorize() {
    setError(null)
    setPopupBlocked(null)
    try {
      const { authorize_url } = await startClaudeOauth()
      if (!openInNewTab(authorize_url)) setPopupBlocked(authorize_url)
      setAuthStarted(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : t('configure_agent.auth_error'))
    }
  }

  async function connect(codeOverride?: string) {
    const codeToExchange = (codeOverride ?? code).trim()
    if (codeToExchange.length === 0) {
      setError(t('configure_agent.paste_code_first'))
      return
    }
    setError(null)
    setExchanging(true)
    try {
      const payload = await exchangeClaudeOauth(codeToExchange)
      if (payload.credential_test.ok) {
        await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
        await queryClient.invalidateQueries({ queryKey: ["credentials"] })
        setCode("")
        onConnected(payload.credential_test)
      } else {
        setError(payload.credential_test.message || t('configure_agent.exchange_error'))
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : t('configure_agent.exchange_catch_error'))
    } finally {
      setExchanging(false)
    }
  }

  function pasteAndConnect(event: React.ClipboardEvent<HTMLInputElement>) {
    const pastedCode = event.clipboardData.getData("text").trim()
    if (!authStarted || pastedCode.length === 0) return

    event.preventDefault()
    setCode(pastedCode)
    setTimeout(() => connect(pastedCode), 0)
  }

  const ambientReady = preflight.status === "done" && preflight.result.ok

  if (backendOutage) {
    // The updating note instead of the authorize walkthrough: the preflight
    // is deferred, so "already connected" can't be shown yet, and starting
    // an OAuth flow against a down backend only ends in errors. The host's
    // secondary action (Cancel / Skip) stays reachable.
    return (
      <div className="space-y-4">
        <StatusBox tone="warning">{t('backend_updating')}</StatusBox>
        {secondaryAction ? <div className="flex items-center justify-end gap-2">{secondaryAction}</div> : null}
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {preflight.status === "checking" ? (
        <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
          <Spinner /> {t('configure_agent.checking_login')}
        </p>
      ) : null}

      {ambientReady ? (
        <StatusBox tone="ok">
          {t('configure_agent.ambient_ready')}
        </StatusBox>
      ) : null}

      <ol className="space-y-3 text-sm text-gray-700 dark:text-gray-300">
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">{t('configure_agent.step1_heading')}</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">
            {t('configure_agent.step1_description')}
          </p>
          <button
            className="mt-2 inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
            onClick={authorize}
            ref={authorizeRef}
            type="button"
          >
            {authStarted ? t('configure_agent.reopen_auth') : t('configure_agent.authorize_claude')}
            <span aria-hidden="true">↗</span>
          </button>
          {popupBlocked ? (
            <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
              {t('configure_agent.popup_blocked')}{" "}
              <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
                {t('configure_agent.open_auth_page')}
              </a>{" "}
              {t('configure_agent.popup_blocked_manually')}
            </p>
          ) : null}
        </li>
        <li className={authStarted ? "" : "opacity-50"}>
          <p className="font-medium text-gray-900 dark:text-gray-100">{t('configure_agent.step2_heading')}</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">{t('configure_agent.step2_description')}</p>
          <label className="mt-2 block">
            <span className="sr-only">{t('configure_agent.input_label')}</span>
            <input
              autoComplete="off"
              className="block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-950 px-3 py-2 font-mono text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
              disabled={!authStarted}
              onChange={(event) => setCode(event.target.value)}
              onPaste={pasteAndConnect}
              placeholder={t('configure_agent.input_placeholder')}
              spellCheck={false}
              type="text"
              value={code}
            />
          </label>
        </li>
      </ol>

      {error ? <StatusBox tone="error">{error}</StatusBox> : null}

      <div className="flex items-center justify-end gap-2">
        {secondaryAction}
        <button
          className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60"
          disabled={!authStarted || exchanging || code.trim().length === 0}
          onClick={() => connect()}
          type="button"
        >
          {exchanging ? (
            <>
              <Spinner light /> {t('configure_agent.connecting')}
            </>
          ) : (
            t('configure_agent.connect')
          )}
        </button>
      </div>
    </div>
  )
}

export function StatusBox({ tone, children }: { tone: "ok" | "warning" | "error"; children: React.ReactNode }) {
  const toneClass = tone === "ok" ? "banner-success" : tone === "warning" ? "banner-warning" : "banner-error"
  return (
    <p className={`${toneClass} px-3 py-2 text-sm`} role={tone === "ok" ? "status" : "alert"}>
      {children}
    </p>
  )
}

export function Spinner({ light }: { light?: boolean }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 animate-spin ${light ? "text-white" : "text-gray-400"}`} fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}
