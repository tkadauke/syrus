import { useEffect, useRef, useState } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { saveGithubToken, testGithubToken, type CredentialTestResult } from "../../api/credentials"
import { useDebouncedProbe, type ProbeState } from "../../hooks/useDebouncedProbe"
import { useT } from "../../hooks/useT"
import { useBackendOutage } from "../../hooks/useBackendUpdate"
import { Button } from "../Button"

const TOKEN_SETTINGS_URL = "https://github.com/settings/tokens"

// Module-level so the probe function stays referentially stable for
// useDebouncedProbe's dependency list.
async function probeGithubToken(token: string): Promise<CredentialTestResult> {
  const payload = await testGithubToken(token)
  return payload.credential_test
}

// The guided GitHub PAT experience: numbered steps (open settings, pick the
// repo + workflow scopes, paste), a debounced live probe of the UNSAVED
// token, and a save that stays disabled until the probe comes back green.
// Extracted from GithubTokenModal so the onboarding modal and the
// credentials page render the identical flow.
export function GithubTokenStep({ onSaved, saveLabel, autoFocus = true }: { onSaved: () => void; saveLabel?: string; autoFocus?: boolean }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [token, setToken] = useState("")
  const [saveError, setSaveError] = useState<string | null>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  // While the desktop shell's backend update has the containers down, the
  // live probe below can only fail — a red "GitHub rejected this token" for
  // a perfectly good paste. Show the shared updating note instead of the
  // form; typed state survives (the component stays mounted) and the form
  // returns when the outage clears.
  const backendOutage = useBackendOutage()
  const test = useDebouncedProbe(token, probeGithubToken, { errorFallback: t('github_token.verify_error') })

  useEffect(() => {
    if (autoFocus && !backendOutage) inputRef.current?.focus()
  }, [autoFocus, backendOutage])

  const tokenValid = test.status === "done" && test.result.ok

  const save = useMutation({
    mutationFn: () => saveGithubToken(token.trim()),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      await queryClient.invalidateQueries({ queryKey: ["credentials"] })
      onSaved()
    },
    onError: (err) => setSaveError(err instanceof Error ? err.message : t('github_token.save_error'))
  })

  function submit(event: React.FormEvent) {
    event.preventDefault()
    setSaveError(null)
    if (!tokenValid) return
    save.mutate()
  }

  if (backendOutage) {
    return (
      <p className="rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-600 dark:border-gray-700 dark:bg-gray-800/50 dark:text-gray-400">
        {t('backend_updating')}
      </p>
    )
  }

  return (
    <form className="space-y-5" onSubmit={submit}>
      <ol className="space-y-4 text-sm text-gray-700 dark:text-gray-300">
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">{t('github_token.step1_heading')}</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">{t('github_token.step1_description')}</p>
          <a className="mt-2 inline-flex items-center gap-1 rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-700 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-white" href={TOKEN_SETTINGS_URL} rel="noreferrer" target="_blank">
            {t('github_token.step1_link')} <span aria-hidden="true">↗</span>
          </a>
        </li>
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">{t('github_token.step2_heading')}</p>
          <p className="mt-1 text-gray-600 dark:text-gray-400">
            {t('github_token.step2_description')}
          </p>
          <ul className="mt-2 space-y-1">
            <li className="flex items-center gap-2">
              <code className="rounded bg-gray-100 px-1.5 py-0.5 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">repo</code>
              <span className="text-gray-600 dark:text-gray-400">{t('github_token.scope_repo')}</span>
            </li>
            <li className="flex items-center gap-2">
              <code className="rounded bg-gray-100 px-1.5 py-0.5 font-mono text-xs text-gray-800 dark:bg-gray-800 dark:text-gray-200">workflow</code>
              <span className="text-gray-600 dark:text-gray-400">{t('github_token.scope_workflow')}</span>
            </li>
          </ul>
        </li>
        <li>
          <p className="font-medium text-gray-900 dark:text-gray-100">{t('github_token.step3_heading')}</p>
          <label className="mt-2 block">
            <span className="sr-only">{t('github_token.input_label')}</span>
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

      {saveError ? (
        <p className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300" role="alert">
          {saveError}
        </p>
      ) : null}

      <div className="flex items-center justify-end gap-2">
        <Button disabled={!tokenValid || save.isPending} type="submit" variant="primary">
          {save.isPending ? t('github_token.saving') : saveLabel ?? t('github_token.save_continue')}
        </Button>
      </div>
    </form>
  )
}

function TokenStatus({ test }: { test: ProbeState }) {
  const { t } = useT("settings")
  if (test.status === "idle") return null
  if (test.status === "testing") {
    return (
      <p className="mt-2 flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
        <Spinner /> {t('github_token.checking_token')}
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

function Spinner() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 animate-spin text-gray-400" fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}

export function CheckIcon() {
  return (
    <svg aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M16.704 5.29a1 1 0 010 1.42l-7.5 7.5a1 1 0 01-1.42 0l-3.5-3.5a1 1 0 011.42-1.42l2.79 2.79 6.79-6.79a1 1 0 011.42 0z" fillRule="evenodd" />
    </svg>
  )
}

export function WarnIcon() {
  return (
    <svg aria-hidden="true" className="mt-0.5 h-4 w-4 shrink-0" fill="currentColor" viewBox="0 0 20 20">
      <path clipRule="evenodd" d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.515 2.625H3.72c-1.345 0-2.188-1.458-1.515-2.625L8.485 2.495zM10 6a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 6zm0 8a1 1 0 100-2 1 1 0 000 2z" fillRule="evenodd" />
    </svg>
  )
}
