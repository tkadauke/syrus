import { useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { saveGithubToken, testGithubToken, type CredentialTestResult } from "../api/credentials"
import { fetchBootstrap } from "../api/bootstrap"
import { CloseIcon } from "./CloseIcon"
import { GithubAppPanel } from "./GithubAppPanel"

const TOKEN_SETTINGS_URL = "https://github.com/settings/tokens"
const TEST_DEBOUNCE_MS = 500

type TestState =
  | { status: "idle" }
  | { status: "testing" }
  | { status: "done"; result: CredentialTestResult }
  | { status: "error"; message: string }

// The GitHub onboarding step requires BOTH credentials, set up in order:
// first a personal access token, then the GitHub App.
export function GithubTokenModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const queryClient = useQueryClient()
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const isAdmin = !!bootstrap.data?.current_user?.admin
  const credStatus = bootstrap.data?.setup_status?.credential_status

  // Local optimistic flag so the flow advances to the App step immediately
  // after the token saves, before the bootstrap refetch lands.
  const [patSaved, setPatSaved] = useState(false)
  const patDone = !!credStatus?.github_pat || patSaved
  const appDone = !!credStatus?.github_app // for the stepper only
  // First the token, then the GitHub App step (which itself does create →
  // install, owned by GithubAppPanel).
  const phase: "pat" | "app" = patDone ? "app" : "pat"

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="github-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="space-y-5 p-5 sm:p-6">
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="github-title">Connect GitHub</h2>
              {phase === "pat" ? (
                <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
                  To monitor and interact with GitHub, and to act as an independent contributor, Syrus requires both a
                  Personal Access Token (PAT) and a custom GitHub App.
                </p>
              ) : null}
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

          <Stepper patDone={patDone} appDone={appDone} active={phase} />

          {phase === "pat" ? (
            <TokenStep onSaved={() => setPatSaved(true)} />
          ) : isAdmin ? (
            // Create → install the GitHub App, owned by the panel.
            <GithubAppPanel onClose={onClose} onSaved={onSaved} />
          ) : (
            <Box tone="muted">
              A personal access token is saved. The GitHub App is registered once per instance by an admin — ask an
              admin to register it to finish this step.
            </Box>
          )}
        </div>
      </section>
    </div>
  )
}

function Stepper({ patDone, appDone, active }: { patDone: boolean; appDone: boolean; active: "pat" | "app" }) {
  const steps = [
    { key: "pat", label: "Personal access token", done: patDone },
    { key: "app", label: "GitHub App", done: appDone }
  ]
  return (
    <ol className="flex items-center gap-2 text-xs font-medium">
      {steps.map((step, index) => {
        const current = active === step.key
        const tone = step.done
          ? "bg-green-100 text-green-700 dark:bg-green-950/60 dark:text-green-300"
          : current
            ? "bg-blue-100 text-blue-700 dark:bg-blue-950/60 dark:text-blue-300"
            : "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-400"
        return (
          <li className="flex items-center gap-2" key={step.key}>
            <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 ${tone}`}>
              <span>{step.done ? "✓" : index + 1}</span> {step.label}
            </span>
            {index < steps.length - 1 ? <span aria-hidden="true" className="text-gray-300 dark:text-gray-600">→</span> : null}
          </li>
        )
      })}
    </ol>
  )
}

// Step 1: paste + verify + save a personal access token.
function TokenStep({ onSaved }: { onSaved: () => void }) {
  const queryClient = useQueryClient()
  const [token, setToken] = useState("")
  const [test, setTest] = useState<TestState>({ status: "idle" })
  const [saveError, setSaveError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const probeSeq = useRef(0)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  useEffect(() => {
    const trimmed = token.trim()
    if (trimmed.length === 0) {
      setTest({ status: "idle" })
      return
    }
    const seq = ++probeSeq.current
    setTest({ status: "testing" })
    const handle = setTimeout(async () => {
      try {
        const payload = await testGithubToken(trimmed)
        if (seq === probeSeq.current) setTest({ status: "done", result: payload.credential_test })
      } catch (err) {
        if (seq === probeSeq.current) setTest({ status: "error", message: err instanceof Error ? err.message : "Could not verify the token." })
      }
    }, TEST_DEBOUNCE_MS)
    return () => clearTimeout(handle)
  }, [token])

  const tokenValid = test.status === "done" && test.result.ok

  const save = useMutation({
    mutationFn: () => saveGithubToken(token.trim()),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      await queryClient.invalidateQueries({ queryKey: ["credentials"] })
      onSaved()
    },
    onError: (err) => setSaveError(err instanceof Error ? err.message : "Could not save the token. Check it and try again.")
  })

  function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaveError(null)
    if (!tokenValid) return
    save.mutate()
  }

  return (
    <form className="space-y-5" onSubmit={submit}>
      <ol className="space-y-4 text-sm text-gray-700 dark:text-gray-300">
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">1. Open GitHub token settings</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">Generate a <span className="font-medium">classic</span> personal access token.</p>
          <a className="mt-2 inline-flex items-center gap-1 rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-700 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-white" href={TOKEN_SETTINGS_URL} rel="noreferrer" target="_blank">
            Open github.com/settings/tokens <span aria-hidden="true">↗</span>
          </a>
        </li>
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">2. Select scopes and expiration</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">
            Under <span className="font-medium">Generate new token (classic)</span>, set
            <span className="font-medium"> Expiration</span> to <span className="font-medium">No expiration</span>, then enable these scopes:
          </p>
          <ul className="mt-2 space-y-1">
            <li className="flex items-center gap-2">
              <code className="rounded bg-gray-100 px-1.5 py-0.5 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">repo</code>
              <span className="text-gray-600 dark:text-gray-400">— clone, branch, and open PRs</span>
            </li>
            <li className="flex items-center gap-2">
              <code className="rounded bg-gray-100 px-1.5 py-0.5 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">workflow</code>
              <span className="text-gray-600 dark:text-gray-400">— update GitHub Actions workflows</span>
            </li>
          </ul>
        </li>
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">3. Paste the token</p>
          <label className="mt-2 block">
            <span className="sr-only">GitHub personal access token</span>
            <input
              autoComplete="off"
              className="block w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-950 px-3 py-2 font-mono text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
              name="github_token"
              onChange={(event) => setToken(event.target.value)}
              placeholder="ghp_…"
              ref={inputRef}
              spellCheck={false}
              type="password"
              value={token}
            />
          </label>
          <TokenStatus test={test} />
        </li>
      </ol>

      {saveError ? <Box tone="error">{saveError}</Box> : null}

      <div className="flex items-center justify-end gap-2">
        <button className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-60" disabled={!tokenValid || save.isPending} type="submit">
          {save.isPending ? "Saving…" : "Save and continue"}
        </button>
      </div>
    </form>
  )
}

function TokenStatus({ test }: { test: TestState }) {
  if (test.status === "idle") return null
  if (test.status === "testing") {
    return (
      <p className="mt-2 flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
        <Spinner /> Checking token…
      </p>
    )
  }
  if (test.status === "error") return <StatusLine tone="error">{test.message}</StatusLine>

  const result = test.result
  if (result.ok) return <StatusLine tone="ok"><CheckIcon /> {result.message}</StatusLine>
  const tone = result.details.login ? "warning" : "error"
  return <StatusLine tone={tone}><WarnIcon /> {result.message}</StatusLine>
}

function StatusLine({ tone, children }: { tone: "ok" | "warning" | "error"; children: React.ReactNode }) {
  const toneClass = tone === "ok" ? "text-green-700 dark:text-green-400" : tone === "warning" ? "text-amber-700 dark:text-amber-400" : "text-red-700 dark:text-red-400"
  return <p className={`mt-2 flex items-start gap-1.5 text-sm ${toneClass}`} role={tone === "ok" ? "status" : "alert"}>{children}</p>
}

function Box({ tone, children }: { tone: "ok" | "muted" | "error"; children: React.ReactNode }) {
  const toneClass = tone === "ok"
    ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/40 dark:text-green-300"
    : tone === "error"
      ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
      : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800/50 dark:text-gray-400"
  return <p className={`rounded border px-3 py-2 text-sm ${toneClass}`} role={tone === "error" ? "alert" : tone === "ok" ? "status" : undefined}>{children}</p>
}

function Spinner() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 animate-spin text-gray-400" fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}

function CheckIcon() {
  return (
    <svg aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M16.704 5.29a1 1 0 010 1.42l-7.5 7.5a1 1 0 01-1.42 0l-3.5-3.5a1 1 0 011.42-1.42l2.79 2.79 6.79-6.79a1 1 0 011.42 0z" fillRule="evenodd" />
    </svg>
  )
}

function WarnIcon() {
  return (
    <svg aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.515 2.625H3.72c-1.345 0-2.188-1.458-1.515-2.625L8.485 2.495zM10 6a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 6zm0 8a1 1 0 100-2 1 1 0 000 2z" fillRule="evenodd" />
    </svg>
  )
}
