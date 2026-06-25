import { useEffect, useState } from "react"
import { useQueryClient } from "@tanstack/react-query"
import { exchangeClaudeOauth, startClaudeOauth, testClaudeCli, type CredentialTestResult } from "../api/credentials"
import { CloseIcon } from "./CloseIcon"

type AgentTab = "claude" | "codex"

type Preflight =
  | { status: "checking" }
  | { status: "done"; result: CredentialTestResult }
  | { status: "error" }

export function ConfigureAgentModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const queryClient = useQueryClient()
  const [tab, setTab] = useState<AgentTab>("claude")
  const [preflight, setPreflight] = useState<Preflight>({ status: "checking" })
  const [authStarted, setAuthStarted] = useState(false)
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const [code, setCode] = useState("")
  const [exchanging, setExchanging] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState<string | null>(null)

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  // Preflight: is Claude already usable on this machine?
  useEffect(() => {
    let cancelled = false
    testClaudeCli()
      .then((payload) => {
        if (!cancelled) setPreflight({ status: "done", result: payload.credential_test })
      })
      .catch(() => {
        if (!cancelled) setPreflight({ status: "error" })
      })
    return () => {
      cancelled = true
    }
  }, [])

  async function authorize() {
    setError(null)
    setPopupBlocked(null)
    try {
      const { authorize_url } = await startClaudeOauth()
      const tab = window.open(authorize_url, "_blank", "noopener,noreferrer")
      if (!tab) setPopupBlocked(authorize_url)
      setAuthStarted(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start authorization.")
    }
  }

  async function connect(codeOverride?: string) {
    const codeToExchange = (codeOverride ?? code).trim()
    if (codeToExchange.length === 0) {
      setError("Paste the code from Claude first.")
      return
    }
    setError(null)
    setExchanging(true)
    try {
      const payload = await exchangeClaudeOauth(codeToExchange)
      if (payload.credential_test.ok) {
        await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
        await queryClient.invalidateQueries({ queryKey: ["credentials"] })
        setConnected(payload.credential_test.message || "Claude connected.")
        onSaved?.()
      } else {
        setError(payload.credential_test.message || "The token Claude returned did not work. Try again.")
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not exchange the code. Try authorizing again.")
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

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="configure-agent-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-5 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="configure-agent-title">
                Configure agent
              </h2>
              <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
                Set the default agent Syrus uses for runs. You can add more or switch later in Agent Settings.
              </p>
            </div>
            <button
              aria-label="Close"
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          {/* Provider tabs. Codex lands in a follow-up step. */}
          <div className="flex border-b border-gray-200 dark:border-gray-700" role="tablist">
            <button
              aria-selected={tab === "claude"}
              className={tabClass(tab === "claude")}
              onClick={() => setTab("claude")}
              role="tab"
              type="button"
            >
              Claude
            </button>
            <button
              aria-disabled="true"
              aria-selected={false}
              className="cursor-not-allowed px-4 py-2 text-sm font-medium text-gray-400 dark:text-gray-600"
              disabled
              role="tab"
              title="Codex support is coming next"
              type="button"
            >
              Codex
              <span className="ml-2 rounded bg-gray-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase text-gray-400 dark:bg-gray-800 dark:text-gray-500">Soon</span>
            </button>
          </div>

          {connected ? (
            <>
              <StatusBox tone="ok">{connected}</StatusBox>
              <div className="flex justify-end">
                <button
                  className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
                  onClick={onClose}
                  type="button"
                >
                  Done
                </button>
              </div>
            </>
          ) : (
            <div className="space-y-4">
              {preflight.status === "checking" ? (
                <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
                  <Spinner /> Checking for an existing Claude login on this machine…
                </p>
              ) : null}

              {ambientReady ? (
                <StatusBox tone="ok">
                  Claude already works on this machine. You can connect a durable token below (recommended for restarts and headless workers), or skip for now.
                </StatusBox>
              ) : null}

              <ol className="space-y-3 text-sm text-gray-700 dark:text-gray-300">
                <li>
                  <p className="font-medium text-gray-900 dark:text-gray-100">1. Authorize with Claude</p>
                  <p className="mt-1 text-gray-600 dark:text-gray-400">
                    Opens <span className="font-medium">claude.ai</span> in a new tab. Approve access (requires a Claude
                    Pro, Max, Team, or Enterprise plan); Claude then shows you a short code.
                  </p>
                  <button
                    className="mt-2 inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
                    onClick={authorize}
                    type="button"
                  >
                    {authStarted ? "Reopen authorization" : "Authorize with Claude"}
                    <span aria-hidden="true">↗</span>
                  </button>
                  {popupBlocked ? (
                    <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
                      Popup blocked.{" "}
                      <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
                        Open the authorization page
                      </a>{" "}
                      manually.
                    </p>
                  ) : null}
                </li>
                <li className={authStarted ? "" : "opacity-50"}>
                  <p className="font-medium text-gray-900 dark:text-gray-100">2. Paste the code</p>
                  <p className="mt-1 text-gray-600 dark:text-gray-400">Copy the code Claude shows and paste it here.</p>
                  <label className="mt-2 block">
                    <span className="sr-only">Authorization code from Claude</span>
                    <input
                      autoComplete="off"
                      className="block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-950 px-3 py-2 font-mono text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
                      disabled={!authStarted}
                      onChange={(event) => setCode(event.target.value)}
                      onPaste={pasteAndConnect}
                      placeholder="paste code here"
                      spellCheck={false}
                      type="text"
                      value={code}
                    />
                  </label>
                </li>
              </ol>

              {error ? <StatusBox tone="error">{error}</StatusBox> : null}

              <div className="flex items-center justify-end gap-2">
                <button
                  className="rounded-md border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"
                  onClick={onClose}
                  type="button"
                >
                  {ambientReady ? "Skip for now" : "Cancel"}
                </button>
                <button
                  className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60"
                  disabled={!authStarted || exchanging || code.trim().length === 0}
                  onClick={() => connect()}
                  type="button"
                >
                  {exchanging ? (
                    <>
                      <Spinner light /> Connecting…
                    </>
                  ) : (
                    "Connect"
                  )}
                </button>
              </div>
            </div>
          )}
        </div>
      </section>
    </div>
  )
}

function tabClass(active: boolean) {
  const base = "px-4 py-2 text-sm font-medium -mb-px border-b-2"
  return active
    ? `${base} border-blue-600 text-blue-700 dark:text-blue-300`
    : `${base} border-transparent text-gray-500 dark:text-gray-400`
}

function StatusBox({ tone, children }: { tone: "ok" | "warning" | "error"; children: React.ReactNode }) {
  const toneClass =
    tone === "ok"
      ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/40 dark:text-green-300"
      : tone === "warning"
        ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-300"
        : "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
  return (
    <p className={`rounded border px-3 py-2 text-sm ${toneClass}`} role={tone === "ok" ? "status" : "alert"}>
      {children}
    </p>
  )
}

function Spinner({ light }: { light?: boolean }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 animate-spin ${light ? "text-white" : "text-gray-400"}`} fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}
