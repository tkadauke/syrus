import { inputClass } from "../../lib/formClasses"
import { useEffect, useRef, useState, type ReactNode, type Ref } from "react"
import { useMutation, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { createConsumer } from "@rails/actioncable"
import {
  clearCredential,
  exchangeCodexOauth,
  savePartialCredentials,
  startCodexOauth,
  testCredential,
  type CredentialTestResult,
  type CredentialsPayload
} from "../../api/credentials"
import { openInNewTab } from "../../lib/desktopShell"
import { useT } from "../../hooks/useT"
import { useSetupStatus } from "../OnboardingEmptyState"
import { GithubAppPanel } from "../GithubAppPanel"
import { GeminiSetupSheet } from "../GeminiSetupSheet"
import { GithubTokenStep, CheckIcon, WarnIcon } from "./GithubTokenStep"
import { ClaudeConnect } from "./ClaudeConnect"
import { errorMessage } from "../../lib/errorMessage"

// Per-provider credential cards for the /credentials page, rebuilt around
// the setup flow's components so first-run and day-two share one experience:
// a clear connected-state summary (no more empty password fields standing in
// for saved secrets), guided not-set copy, probe-before-save where an
// unsaved-value endpoint exists (GitHub, Gemini), per-card partial saves,
// and per-card errors instead of a stack of global banners.
//
// Saved-credential probes stay behind the explicit Test button — the server
// probe shells out to provider CLIs with 30s timeouts, so nothing here
// auto-tests stored secrets on mount. The same rule covers the Claude CLI
// preflight: ClaudeConnect only mounts after an explicit Connect/Replace
// click, never on page load.

const queryKey = ["credentials"] as const

type CardProps = {
  payload: CredentialsPayload
  onNotice: (message: string | null) => void
}

type OpenCodeBackend = "openai_api" | "ollama" | "azure_openai"

const OPENCODE_BACKEND_OPTIONS: Record<OpenCodeBackend, { label: string; modelPlaceholder: string; endpointPlaceholder?: string }> = {
  openai_api: {
    label: "OpenAI API",
    modelPlaceholder: "gpt-5.2"
  },
  ollama: {
    label: "Ollama",
    modelPlaceholder: "qwen3-coder:30b",
    endpointPlaceholder: "http://localhost:11434/v1"
  },
  azure_openai: {
    label: "Azure OpenAI",
    modelPlaceholder: "my-gpt-5-deployment",
    endpointPlaceholder: "https://RESOURCE_NAME.openai.azure.com/openai/v1"
  }
}

// Write a mutation's payload snapshot into the credentials cache.
// - Strips the server's generic `message` ("Credentials updated.") so the
//   page-level payload-message effect cannot overwrite the card's specific
//   notice with it.
// - Follows up with an invalidation so concurrent partial PATCHes (e.g. a
//   mode change racing a key save) reconcile against a fresh GET instead of
//   whichever full snapshot happened to land last.
export function cacheCredentials(queryClient: QueryClient, updated: CredentialsPayload) {
  const { message: _ignored, ...snapshot } = updated
  queryClient.setQueryData(queryKey, snapshot)
  void queryClient.invalidateQueries({ queryKey })
}

// ---------- shared shell ----------

export function CredentialCard({
  title,
  connected,
  description,
  error,
  children,
  testId,
  headingRef
}: {
  title: string
  connected: boolean
  description?: ReactNode
  error?: string | null
  children: ReactNode
  testId: string
  headingRef?: Ref<HTMLHeadingElement>
}) {
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5" data-testid={testId}>
      <div className="flex items-start justify-between gap-3">
        <div>
          {/* tabIndex=-1 so state flips that unmount the activated control can
              hand keyboard focus somewhere sensible instead of document.body. */}
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100 focus:outline-none" ref={headingRef} tabIndex={-1}>
            {title}
          </h2>
          {description ? <div className="mt-1 text-xs leading-5 text-gray-500 dark:text-gray-400">{description}</div> : null}
        </div>
        <ConnectionPill connected={connected} />
      </div>
      {error ? (
        <p className="mt-3 rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300" role="alert">
          {error}
        </p>
      ) : null}
      <div className="mt-4">{children}</div>
    </section>
  )
}

// Focus target for card-mode flips: entering an editor focuses its first
// control (autoFocus on mount); leaving it (Cancel / save / clear) focuses
// the card heading so keyboard users are not dropped onto document.body.
function useCardFocus() {
  const headingRef = useRef<HTMLHeadingElement>(null)
  const focusHeading = () => headingRef.current?.focus()
  return { headingRef, focusHeading }
}

function ConnectionPill({ connected }: { connected: boolean }) {
  const { t } = useT("settings")
  return connected ? (
    <span className="inline-flex shrink-0 items-center gap-1 rounded-full bg-emerald-100 px-2.5 py-1 text-xs font-medium text-emerald-700 dark:bg-emerald-950/60 dark:text-emerald-300">
      <svg aria-hidden="true" className="h-3 w-3" fill="currentColor" viewBox="0 0 20 20">
        <path clipRule="evenodd" d="M16.704 5.29a1 1 0 010 1.42l-7.5 7.5a1 1 0 01-1.42 0l-3.5-3.5a1 1 0 011.42-1.42l2.79 2.79 6.79-6.79a1 1 0 011.42 0z" fillRule="evenodd" />
      </svg>
      {t('credential_cards.connected')}
    </span>
  ) : (
    <span className="inline-flex shrink-0 items-center rounded-full bg-amber-100 px-2.5 py-1 text-xs font-medium text-amber-700 dark:bg-amber-950/60 dark:text-amber-300">
      {t('credential_cards.not_set')}
    </span>
  )
}

// SVG check/warn iconography (the setup flow's language), not emoji.
export function CredentialTestResultLine({ result }: { result?: CredentialTestResult }) {
  if (!result) return null
  const scopes = result.details.scopes || []
  const details = [
    result.details.login ? `@${result.details.login}` : null,
    scopes.length > 0 ? `scopes: ${scopes.join(", ")}` : null,
    (result.details as { model?: string }).model ?? null
  ].filter(Boolean)
  return (
    <p
      className={`mt-2 flex items-start gap-1.5 text-xs ${result.ok ? "text-emerald-700 dark:text-emerald-300" : "text-red-700 dark:text-red-300"}`}
      role={result.ok ? "status" : "alert"}
    >
      {result.ok ? <CheckIcon /> : <WarnIcon />}
      <span>
        {result.message}
        {details.length > 0 ? <span className="ml-1 text-gray-500 dark:text-gray-400">({details.join(" · ")})</span> : null}
      </span>
    </p>
  )
}

// Test (saved credential) + Clear plumbing shared by every card, with the
// error captured per-card instead of surfacing in a page-top banner stack.
function useCredentialActions(onNotice: (message: string | null) => void, focusAfterClear?: () => void) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [testResult, setTestResult] = useState<CredentialTestResult | undefined>(undefined)
  const [error, setError] = useState<string | null>(null)

  const test = useMutation({
    mutationFn: (credential: string) => testCredential(credential),
    onMutate: () => setError(null),
    onSuccess: (payload) => {
      setTestResult(payload.credential_test)
      onNotice(payload.message || null)
    },
    onError: (err) => setError(errorMessage(err, t('credential_cards.test_error')))
  })

  const clear = useMutation({
    mutationFn: (credential: string) => clearCredential(credential),
    onMutate: () => setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      setTestResult(undefined)
      onNotice(updated.message || null)
      // The Clear button unmounts when the card flips to its not-set state.
      focusAfterClear?.()
    },
    onError: (err) => setError(errorMessage(err, t('credential_cards.clear_error')))
  })

  return { test, clear, testResult, setTestResult, error, setError }
}

function TestButton({ actions, credential }: { actions: ReturnType<typeof useCredentialActions>; credential: string }) {
  const { t } = useT("settings")
  return (
    <button className={secondaryButtonClass()} disabled={actions.test.isPending} onClick={() => actions.test.mutate(credential)} type="button">
      {actions.test.isPending ? t('credential_cards.testing') : t('credential_cards.test')}
    </button>
  )
}

function ClearButton({ actions, credential }: { actions: ReturnType<typeof useCredentialActions>; credential: string }) {
  const { t } = useT("settings")
  return (
    <button
      className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:text-red-300 dark:disabled:text-red-500"
      disabled={actions.clear.isPending}
      onClick={() => actions.clear.mutate(credential)}
      type="button"
    >
      {t('credential_cards.clear')}
    </button>
  )
}

function secondaryButtonClass() {
  return "rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600"
}

function primaryButtonClass() {
  return "rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-700 disabled:cursor-not-allowed disabled:opacity-60"
}


// ---------- GitHub ----------

export function GithubCredentialCard({ payload, onNotice }: CardProps) {
  const { t } = useT("settings")
  const set = payload.credential_status.github_token
  const [editing, setEditing] = useState(false)
  const [appPanelOpen, setAppPanelOpen] = useState(false)
  const { headingRef, focusHeading } = useCardFocus()
  const actions = useCredentialActions(onNotice, focusHeading)
  const setupStatus = useSetupStatus()
  const showEditor = editing || !set
  const appRegistered = !!setupStatus?.credential_status.github_app

  return (
    <CredentialCard
      connected={set}
      description={t('account_settings.github_access_desc')}
      error={actions.error}
      headingRef={headingRef}
      testId="credential-card-github"
      title={t('credential_cards.github_title')}
    >
      {showEditor ? (
        <div className="space-y-3">
          <GithubTokenStep
            // Focus the token input only when the user explicitly opened the
            // editor via Replace — never steal focus on page load.
            autoFocus={editing}
            onSaved={() => {
              setEditing(false)
              actions.setTestResult(undefined)
              onNotice(t('credential_cards.github_saved_notice'))
              focusHeading()
            }}
            saveLabel={t('credential_cards.github_save_label')}
          />
          {set ? (
            <div className="flex justify-end">
              <button
                className={secondaryButtonClass()}
                onClick={() => {
                  setEditing(false)
                  focusHeading()
                }}
                type="button"
              >
                {t('credential_cards.cancel')}
              </button>
            </div>
          ) : null}
        </div>
      ) : (
        <div className="space-y-3">
          <p className="text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.github_summary')}</p>
          <GithubRateLimitLine payload={payload} />
          <CredentialTestResultLine result={actions.testResult} />
          <div className="flex flex-wrap gap-2">
            <TestButton actions={actions} credential="github_token" />
            <button className={secondaryButtonClass()} onClick={() => setEditing(true)} type="button">
              {t('credential_cards.replace')}
            </button>
            <ClearButton actions={actions} credential="github_token" />
          </div>
        </div>
      )}

      {setupStatus ? (
        <div className="mt-4 border-t border-gray-100 dark:border-gray-800 pt-3">
          <div className="flex flex-wrap items-center justify-between gap-2 text-sm">
            <span className={`flex items-center gap-1.5 ${appRegistered ? "text-emerald-700 dark:text-emerald-300" : "text-amber-700 dark:text-amber-300"}`}>
              {appRegistered ? <CheckIcon /> : <WarnIcon />}
              {appRegistered ? t('credential_cards.github_app_registered') : t('credential_cards.github_app_missing')}
            </span>
            {payload.user.admin ? (
              <button className={secondaryButtonClass()} onClick={() => setAppPanelOpen((open) => !open)} type="button">
                {appPanelOpen ? t('credential_cards.github_app_hide') : t('credential_cards.github_app_manage')}
              </button>
            ) : null}
          </div>
          {!payload.user.admin && !appRegistered ? (
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t('credential_cards.github_app_admin_only')}</p>
          ) : null}
          {appPanelOpen ? (
            <div className="mt-3">
              <GithubAppPanel onClose={() => setAppPanelOpen(false)} />
            </div>
          ) : null}
        </div>
      ) : null}
    </CredentialCard>
  )
}

function GithubRateLimitLine({ payload }: { payload: CredentialsPayload }) {
  const { t } = useT("settings")
  if (!payload.github_rate_limit) {
    return <p className="text-xs text-gray-400 dark:text-gray-500">{t('account_settings.github_quota_not_recorded')}</p>
  }

  return (
    <p className="text-xs text-gray-500 dark:text-gray-400">
      {t('account_settings.github_quota_prefix')} <strong>{payload.github_rate_limit.remaining}</strong> / {payload.github_rate_limit.limit}{" "}
      {t('account_settings.github_quota_suffix', { resource: payload.github_rate_limit.resource })}
    </p>
  )
}

// ---------- Claude ----------

export function ClaudeCredentialCard({ payload, onNotice }: CardProps) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const set = payload.credential_status.claude_oauth_token
  const [connecting, setConnecting] = useState(false)
  const [manualToken, setManualToken] = useState("")
  const { headingRef, focusHeading } = useCardFocus()
  const actions = useCredentialActions(onNotice, focusHeading)

  const saveManual = useMutation({
    mutationFn: () => savePartialCredentials({ claude_oauth_token: manualToken.trim() }),
    onMutate: () => actions.setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      setManualToken("")
      setConnecting(false)
      actions.setTestResult(undefined)
      onNotice(t('credential_cards.claude_saved_notice'))
      focusHeading()
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  return (
    <CredentialCard
      connected={set}
      description={t('credential_cards.claude_description')}
      error={actions.error}
      headingRef={headingRef}
      testId="credential-card-claude"
      title={t('credential_cards.claude_title')}
    >
      {connecting ? (
        <div className="space-y-3">
          {/* Mounted only after an explicit Connect/Replace click: the connect
              flow preflights `claude --print` server-side on mount (a real CLI
              spawn), which must never happen on a plain page view. */}
          <ClaudeConnect
            autoFocus
            onConnected={(result) => {
              setConnecting(false)
              actions.setTestResult(result)
              onNotice(result.message || t('configure_agent.connected_default'))
              focusHeading()
            }}
            secondaryAction={
              <button
                className={secondaryButtonClass()}
                onClick={() => {
                  setConnecting(false)
                  focusHeading()
                }}
                type="button"
              >
                {t('credential_cards.cancel')}
              </button>
            }
          />
          <details className="rounded border border-gray-200 dark:border-gray-700 p-3">
            <summary className="cursor-pointer text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.claude_manual_summary')}</summary>
            <div className="mt-3 space-y-2">
              <p className="text-xs leading-5 text-gray-500 dark:text-gray-400">
                {t('account_settings.claude_token_help', { command: "claude setup-token", env: "CLAUDE_CODE_OAUTH_TOKEN" })}{" "}
                <a
                  className="font-medium text-terracotta-700 dark:text-terracotta-300 underline hover:text-terracotta-600"
                  href="https://code.claude.com/docs/en/authentication#generate-a-long-lived-token"
                  rel="noreferrer"
                  target="_blank"
                >
                  {t('account_settings.anthropic_docs')}
                </a>
                .
              </p>
              <div className="flex gap-2">
                <input
                  aria-label={t('credential_cards.claude_manual_label')}
                  autoComplete="off"
                  className={inputClass()}
                  onChange={(event) => setManualToken(event.target.value)}
                  spellCheck={false}
                  type="password"
                  value={manualToken}
                />
                <button
                  className={secondaryButtonClass()}
                  disabled={manualToken.trim().length === 0 || saveManual.isPending}
                  onClick={() => saveManual.mutate()}
                  type="button"
                >
                  {saveManual.isPending ? t('credential_cards.saving') : t('credential_cards.save')}
                </button>
              </div>
            </div>
          </details>
        </div>
      ) : set ? (
        <div className="space-y-3">
          <p className="text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.claude_summary')}</p>
          <CredentialTestResultLine result={actions.testResult} />
          <div className="flex flex-wrap gap-2">
            <TestButton actions={actions} credential="claude_oauth_token" />
            <button className={secondaryButtonClass()} onClick={() => setConnecting(true)} type="button">
              {t('credential_cards.replace')}
            </button>
            <ClearButton actions={actions} credential="claude_oauth_token" />
          </div>
        </div>
      ) : (
        <button className={primaryButtonClass()} onClick={() => setConnecting(true)} type="button">
          {t('credential_cards.claude_set_up')}
        </button>
      )}
    </CredentialCard>
  )
}

// ---------- Codex ----------

export function CodexCredentialCard({ payload, onNotice }: CardProps) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const { headingRef, focusHeading } = useCardFocus()
  const actions = useCredentialActions(onNotice, focusHeading)
  const mode = payload.user.codex_auth_mode
  const connected = mode === "chatgpt_login" ? payload.credential_status.codex_auth_json : payload.credential_status.codex_api_key
  // Lives at CARD level (not inside the ChatGPT section) so an auth-mode flip
  // mid-authorization cannot unmount the ActionCable callback subscription
  // and drop the OAuth code.
  const chatGptFlow = useCodexChatGptFlow(actions, onNotice)

  // The auth-mode select lives INSIDE the card because the saved-credential
  // probe reports wrong_mode when the stored secret does not match the mode.
  const saveMode = useMutation({
    mutationFn: (nextMode: string) => savePartialCredentials({ codex_auth_mode: nextMode }),
    onMutate: () => actions.setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      onNotice(t('credential_cards.codex_mode_saved_notice'))
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  return (
    <CredentialCard
      connected={connected}
      description={t('credential_cards.codex_description')}
      error={actions.error}
      headingRef={headingRef}
      testId="credential-card-codex"
      title={t('credential_cards.codex_title')}
    >
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
        {t('credential_cards.codex_auth_mode')}
        <select
          className={`mt-2 ${inputClass()}`}
          disabled={saveMode.isPending}
          onChange={(event) => saveMode.mutate(event.target.value)}
          value={mode}
        >
          <option value="api_key">{t('account_settings.codex_api_key')}</option>
          <option value="chatgpt_login">{t('account_settings.codex_chatgpt_login')}</option>
        </select>
      </label>

      <div className="mt-4">
        {mode === "chatgpt_login" ? (
          <CodexChatGptSection actions={actions} flow={chatGptFlow} focusHeading={focusHeading} set={payload.credential_status.codex_auth_json} />
        ) : (
          <CodexApiKeySection actions={actions} focusHeading={focusHeading} onNotice={onNotice} set={payload.credential_status.codex_api_key} />
        )}
      </div>
    </CredentialCard>
  )
}

function CodexApiKeySection({
  set,
  actions,
  onNotice,
  focusHeading
}: {
  set: boolean
  actions: ReturnType<typeof useCredentialActions>
  onNotice: (message: string | null) => void
  focusHeading: () => void
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [apiKey, setApiKey] = useState("")
  const showEditor = editing || !set

  const save = useMutation({
    mutationFn: () => savePartialCredentials({ codex_api_key: apiKey.trim() }),
    onMutate: () => actions.setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      setApiKey("")
      setEditing(false)
      actions.setTestResult(undefined)
      onNotice(t('credential_cards.codex_saved_notice'))
      focusHeading()
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  if (showEditor) {
    return (
      <div className="space-y-2">
        <div className="flex gap-2">
          <input
            aria-label={t('credential_cards.codex_api_key_label')}
            autoComplete="off"
            // Only focus when the editor was opened via Replace, not when it
            // renders because no key is saved yet (page load).
            autoFocus={editing}
            className={inputClass()}
            onChange={(event) => setApiKey(event.target.value)}
            placeholder="sk-…"
            spellCheck={false}
            type="password"
            value={apiKey}
          />
          <button className={secondaryButtonClass()} disabled={apiKey.trim().length === 0 || save.isPending} onClick={() => save.mutate()} type="button">
            {save.isPending ? t('credential_cards.saving') : t('credential_cards.save')}
          </button>
          {set ? (
            <button
              className={secondaryButtonClass()}
              onClick={() => {
                setEditing(false)
                focusHeading()
              }}
              type="button"
            >
              {t('credential_cards.cancel')}
            </button>
          ) : null}
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.codex_api_key_summary')}</p>
      <CredentialTestResultLine result={actions.testResult} />
      <div className="flex flex-wrap gap-2">
        <TestButton actions={actions} credential="codex_api_key" />
        <button className={secondaryButtonClass()} onClick={() => setEditing(true)} type="button">
          {t('credential_cards.replace')}
        </button>
        <ClearButton actions={actions} credential="codex_api_key" />
      </div>
    </div>
  )
}

// All state for the Codex ChatGPT OAuth flow, held at CARD level so the
// ActionCable auto-exchange subscription and an in-flight authorization
// survive auth-mode flips that unmount the section UI.
function useCodexChatGptFlow(actions: ReturnType<typeof useCredentialActions>, onNotice: (message: string | null) => void) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [reauthorizing, setReauthorizing] = useState(false)
  const [authStarted, setAuthStarted] = useState(false)
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const [authCode, setAuthCode] = useState("")
  const [autoConnecting, setAutoConnecting] = useState(false)
  const [manualJson, setManualJson] = useState("")

  const start = useMutation({
    mutationFn: startCodexOauth,
    onMutate: () => actions.setError(null),
    onSuccess: (started) => {
      setPopupBlocked(openInNewTab(started.authorize_url) ? null : started.authorize_url)
      setAuthStarted(true)
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  const exchange = useMutation({
    mutationFn: (code?: string) => exchangeCodexOauth((code || authCode).trim()),
    // Clear any stale card error (e.g. from a failed earlier exchange) the
    // moment a retry starts, so a success never renders under a red banner.
    onMutate: () => actions.setError(null),
    onSuccess: async (updated) => {
      actions.setError(null)
      actions.setTestResult(updated.credential_test)
      await queryClient.invalidateQueries({ queryKey })
      setAuthCode("")
      setAutoConnecting(false)
      setReauthorizing(false)
      onNotice(updated.message || t('credential_cards.codex_saved_notice'))
    },
    onError: (err) => {
      setAutoConnecting(false)
      actions.setError(errorMessage(err, t('credential_cards.save_error')))
    }
  })

  const saveManual = useMutation({
    mutationFn: () => savePartialCredentials({ codex_auth_json: manualJson }),
    onMutate: () => actions.setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      setManualJson("")
      setReauthorizing(false)
      actions.setTestResult(undefined)
      onNotice(t('credential_cards.codex_saved_notice'))
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  // The desktop/browser callback listener broadcasts the OAuth code over the
  // user's app-event channel; auto-exchange it so the operator never has to
  // paste. Ref-routed so the subscription (created once per auth start)
  // always calls the latest mutation.
  const autoExchangeRef = useRef((code: string) => {
    setAuthCode(code)
    setAutoConnecting(true)
    exchange.mutate(code)
  })
  autoExchangeRef.current = (code: string) => {
    setAuthCode(code)
    setAutoConnecting(true)
    exchange.mutate(code)
  }

  useEffect(() => {
    if (!authStarted) return

    const consumer = createConsumer()
    const subscription = consumer.subscriptions.create(
      { channel: "AppUserChannel" },
      {
        received(data: unknown) {
          const event = data as { type?: string; payload?: { code?: string } }
          const code = event.type === "codex_oauth.callback" ? event.payload?.code?.trim() : ""
          if (code) autoExchangeRef.current(code)
        }
      }
    )

    return () => subscription.unsubscribe()
  }, [authStarted])

  return {
    reauthorizing,
    setReauthorizing,
    authStarted,
    popupBlocked,
    authCode,
    setAuthCode,
    autoConnecting,
    manualJson,
    setManualJson,
    start,
    exchange,
    saveManual
  }
}

function CodexChatGptSection({
  set,
  actions,
  flow,
  focusHeading
}: {
  set: boolean
  actions: ReturnType<typeof useCredentialActions>
  flow: ReturnType<typeof useCodexChatGptFlow>
  focusHeading: () => void
}) {
  const { t } = useT("settings")
  const showFlow = flow.reauthorizing || !set

  if (!showFlow) {
    return (
      <div className="space-y-3">
        <p className="text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.codex_auth_json_summary')}</p>
        <CredentialTestResultLine result={actions.testResult} />
        <div className="flex flex-wrap gap-2">
          <TestButton actions={actions} credential="codex_auth_json" />
          <button className={secondaryButtonClass()} onClick={() => flow.setReauthorizing(true)} type="button">
            {t('credential_cards.reauthorize')}
          </button>
          <ClearButton actions={actions} credential="codex_auth_json" />
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <button
          // Focus the flow's first control when it was revealed explicitly
          // via Re-authorize (which unmounts the activated button).
          autoFocus={flow.reauthorizing}
          className="rounded bg-gray-900 dark:bg-gray-100 px-3 py-2 text-sm font-medium text-white dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-white disabled:cursor-not-allowed disabled:bg-gray-300 dark:disabled:bg-gray-700"
          disabled={flow.start.isPending}
          onClick={() => flow.start.mutate()}
          type="button"
        >
          {flow.start.isPending ? t('credential_cards.opening') : t('credential_cards.codex_authorize')}
        </button>
        {set ? (
          <button
            className={secondaryButtonClass()}
            onClick={() => {
              flow.setReauthorizing(false)
              focusHeading()
            }}
            type="button"
          >
            {t('credential_cards.cancel')}
          </button>
        ) : null}
      </div>
      {flow.popupBlocked ? (
        <p className="text-xs text-amber-600 dark:text-amber-300">
          {t('account_settings.codex_popup_blocked')}{" "}
          <a className="font-medium underline" href={flow.popupBlocked} rel="noreferrer" target="_blank">
            {t('account_settings.codex_open_auth')}
          </a>
          .
        </p>
      ) : null}
      {flow.autoConnecting ? <p className="text-xs text-gray-500 dark:text-gray-400">{t('account_settings.connecting')}</p> : null}
      <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
        <input
          aria-label={t('credential_cards.codex_code_label')}
          autoComplete="off"
          className={inputClass()}
          onChange={(event) => flow.setAuthCode(event.target.value)}
          placeholder={flow.authStarted ? t('credential_cards.codex_code_placeholder') : t('credential_cards.codex_code_placeholder_disabled')}
          type="text"
          value={flow.authCode}
        />
        <button
          className={secondaryButtonClass()}
          disabled={flow.exchange.isPending || flow.authCode.trim().length === 0}
          onClick={() => flow.exchange.mutate(undefined)}
          type="button"
        >
          {flow.exchange.isPending ? t('account_settings.connecting') : t('credential_cards.connect')}
        </button>
      </div>
      <CredentialTestResultLine result={actions.testResult} />

      <details className="rounded border border-gray-200 dark:border-gray-700 p-3">
        <summary className="cursor-pointer text-sm text-gray-700 dark:text-gray-300">{t('account_settings.paste_auth_json')}</summary>
        <div className="mt-3 space-y-2">
          <textarea
            aria-label={t('credential_cards.codex_auth_json_label')}
            className={`${inputClass()} font-mono text-xs`}
            onChange={(event) => flow.setManualJson(event.target.value)}
            rows={6}
            value={flow.manualJson}
          />
          <div className="flex items-center justify-between gap-2">
            <p className="text-xs text-gray-500 dark:text-gray-400">{t('account_settings.auth_json_help')}</p>
            <button
              className={secondaryButtonClass()}
              disabled={flow.manualJson.trim().length === 0 || flow.saveManual.isPending}
              onClick={() => flow.saveManual.mutate()}
              type="button"
            >
              {flow.saveManual.isPending ? t('credential_cards.saving') : t('credential_cards.save')}
            </button>
          </div>
        </div>
      </details>
    </div>
  )
}

// ---------- OpenCode ----------

export function OpenCodeCredentialCard({ payload, onNotice }: CardProps) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const { headingRef, focusHeading } = useCardFocus()
  const actions = useCredentialActions(onNotice, focusHeading)
  const initialBackend = normalizedOpenCodeBackend(payload.user.opencode_backend || "", payload.options.opencode_backends)
  const [editing, setEditing] = useState(false)
  const [backend, setBackend] = useState<OpenCodeBackend>(initialBackend)
  const [model, setModel] = useState(payload.user.opencode_model || "")
  const [apiKey, setApiKey] = useState("")
  const [endpointUrl, setEndpointUrl] = useState(payload.user.opencode_endpoint_url || "")
  const backendOption = OPENCODE_BACKEND_OPTIONS[backend]
  const needsApiKey = backend === "openai_api" || backend === "azure_openai"
  const needsEndpoint = backend === "ollama" || backend === "azure_openai"
  const connected = opencodeConfigured({
    backend,
    model,
    apiKeySet: payload.credential_status.opencode_api_key,
    endpointUrl
  })
  const showEditor = editing || !connected

  useEffect(() => {
    const nextBackend = normalizedOpenCodeBackend(payload.user.opencode_backend || "", payload.options.opencode_backends)
    setBackend(nextBackend)
    setModel(payload.user.opencode_model || "")
    setEndpointUrl(payload.user.opencode_endpoint_url || "")
    setApiKey("")
  }, [payload])

  const save = useMutation({
    mutationFn: () => savePartialCredentials({
      opencode_backend: backend,
      opencode_model: model,
      opencode_api_key: apiKey.trim(),
      opencode_endpoint_url: endpointUrl
    }),
    onMutate: () => actions.setError(null),
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      setApiKey("")
      setEditing(false)
      onNotice(t('credential_cards.opencode_saved_notice'))
      focusHeading()
    },
    onError: (err) => actions.setError(errorMessage(err, t('credential_cards.save_error')))
  })

  return (
    <CredentialCard
      connected={connected}
      description={t('credential_cards.opencode_description')}
      error={actions.error}
      headingRef={headingRef}
      testId="credential-card-opencode"
      title={t('credential_cards.opencode_title')}
    >
      {showEditor ? (
        <div className="space-y-4">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
            {t('credential_cards.opencode_backend')}
            <select
              autoFocus={editing}
              className={`mt-2 ${inputClass()}`}
              onChange={(event) => setBackend(normalizedOpenCodeBackend(event.target.value, payload.options.opencode_backends))}
              value={backend}
            >
              {payload.options.opencode_backends.map((option) => (
                <option key={option} value={option}>{openCodeBackendLabel(option)}</option>
              ))}
            </select>
          </label>

          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
            {t('credential_cards.opencode_model')}
            <input
              className={`mt-2 ${inputClass()}`}
              onChange={(event) => setModel(event.target.value)}
              placeholder={backendOption.modelPlaceholder}
              type="text"
              value={model}
            />
          </label>

          {needsApiKey ? (
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
              {t('credential_cards.opencode_api_key')}
              <div className="mt-2 flex gap-2">
                <input
                  autoComplete="off"
                  className={inputClass()}
                  onChange={(event) => setApiKey(event.target.value)}
                  type="password"
                  value={apiKey}
                />
                {payload.credential_status.opencode_api_key ? <ClearButton actions={actions} credential="opencode_api_key" /> : null}
              </div>
            </label>
          ) : null}

          {needsEndpoint ? (
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
              {t('credential_cards.opencode_endpoint_url')}
              <input
                className={`mt-2 ${inputClass()}`}
                onChange={(event) => setEndpointUrl(event.target.value)}
                placeholder={backendOption.endpointPlaceholder}
                type="url"
                value={endpointUrl}
              />
            </label>
          ) : null}

          <OpenCodeConfigPreview
            apiKeySet={payload.credential_status.opencode_api_key || apiKey.trim().length > 0}
            backend={backend}
            endpointUrl={endpointUrl}
            model={model}
          />

          <div className="flex flex-wrap gap-2">
            <button className={primaryButtonClass()} disabled={save.isPending} onClick={() => save.mutate()} type="button">
              {save.isPending ? t('credential_cards.saving') : t('credential_cards.save')}
            </button>
            {connected ? (
              <button
                className={secondaryButtonClass()}
                onClick={() => {
                  setEditing(false)
                  focusHeading()
                }}
                type="button"
              >
                {t('credential_cards.cancel')}
              </button>
            ) : null}
          </div>
        </div>
      ) : (
        <div className="space-y-3">
          <p className="text-sm text-gray-700 dark:text-gray-300">
            {t('credential_cards.opencode_summary', { backend: openCodeBackendLabel(backend), model: model || backendOption.modelPlaceholder })}
          </p>
          <OpenCodeConfigPreview
            apiKeySet={payload.credential_status.opencode_api_key}
            backend={backend}
            endpointUrl={endpointUrl}
            model={model}
          />
          <div className="flex flex-wrap gap-2">
            <button className={secondaryButtonClass()} onClick={() => setEditing(true)} type="button">
              {t('credential_cards.replace')}
            </button>
            {payload.credential_status.opencode_api_key ? <ClearButton actions={actions} credential="opencode_api_key" /> : null}
          </div>
        </div>
      )}
    </CredentialCard>
  )
}

function OpenCodeConfigPreview({
  apiKeySet,
  backend,
  endpointUrl,
  model
}: {
  apiKeySet: boolean
  backend: OpenCodeBackend
  endpointUrl: string
  model: string
}) {
  const { t } = useT("settings")
  const config = openCodeConfigPreview({ apiKeySet, backend, endpointUrl, model })

  return (
    <section aria-label={t('credential_cards.opencode_preview')} className="rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-950/40 p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t('credential_cards.opencode_preview')}</h3>
        <span className="text-xs text-gray-500 dark:text-gray-400">{t('credential_cards.read_only')}</span>
      </div>
      <pre className="mt-3 max-h-80 overflow-auto rounded bg-gray-950 p-3 text-xs leading-5 text-gray-100">
        {JSON.stringify(config, null, 2)}
      </pre>
    </section>
  )
}

function normalizedOpenCodeBackend(value: string, allowedBackends: string[]): OpenCodeBackend {
  const fallback = allowedBackends.includes("openai_api") ? "openai_api" : allowedBackends[0]
  const backend = value || fallback
  return isOpenCodeBackend(backend) ? backend : "openai_api"
}

function isOpenCodeBackend(value: string): value is OpenCodeBackend {
  return Object.prototype.hasOwnProperty.call(OPENCODE_BACKEND_OPTIONS, value)
}

function openCodeBackendLabel(backend: string) {
  return isOpenCodeBackend(backend) ? OPENCODE_BACKEND_OPTIONS[backend].label : backend
}

function opencodeConfigured({
  backend,
  model,
  apiKeySet,
  endpointUrl
}: {
  backend: OpenCodeBackend
  model: string
  apiKeySet: boolean
  endpointUrl: string
}) {
  if (model.trim().length === 0) return false
  if (backend === "ollama") return endpointUrl.trim().length > 0
  if (backend === "azure_openai") return apiKeySet && endpointUrl.trim().length > 0
  return apiKeySet
}

function openCodeConfigPreview({
  apiKeySet,
  backend,
  endpointUrl,
  model
}: {
  apiKeySet: boolean
  backend: OpenCodeBackend
  endpointUrl: string
  model: string
}) {
  const modelId = model.trim() || OPENCODE_BACKEND_OPTIONS[backend].modelPlaceholder
  const providerId = openCodeProviderId(backend)
  const providerConfig: Record<string, unknown> = {}
  const providerOptions: Record<string, string> = {}

  if (backend === "ollama") {
    providerConfig.npm = "@ai-sdk/openai-compatible"
    providerConfig.name = "Ollama"
  } else if (backend === "azure_openai") {
    providerConfig.name = "Azure OpenAI"
  }

  if (endpointUrl.trim().length > 0) providerOptions.baseURL = endpointUrl.trim()
  if (apiKeySet && backend !== "ollama") providerOptions.apiKey = "<encrypted>"
  if (Object.keys(providerOptions).length > 0) providerConfig.options = providerOptions

  return {
    "$schema": "https://opencode.ai/config.json",
    model: `${providerId}/${modelId}`,
    provider: {
      [providerId]: {
        ...providerConfig,
        models: {
          [modelId]: {
            name: modelId
          }
        }
      }
    }
  }
}

function openCodeProviderId(backend: OpenCodeBackend) {
  if (backend === "openai_api") return "openai"
  if (backend === "azure_openai") return "azure"
  return "ollama"
}

// ---------- Gemini ----------

export function GeminiCredentialCard({ payload, onNotice }: CardProps) {
  // settings is the default namespace; the Gemini setup sheet's copy lives in
  // the chat namespace (shared with Chat.tsx and ConfigureAgentModal).
  const { t } = useT(["settings", "chat"])
  const set = payload.credential_status.gemini_api_key
  const [sheetOpen, setSheetOpen] = useState(false)
  const { headingRef, focusHeading } = useCardFocus()
  const actions = useCredentialActions(onNotice, focusHeading)

  const sheetLabels = {
    title: t("chat:gemini_setup_title"),
    intro: t("chat:gemini_setup_intro"),
    getKey: t("chat:gemini_setup_get_key"),
    keyPlaceholder: t("chat:gemini_setup_placeholder"),
    validateAndSave: t("chat:gemini_setup_save"),
    validating: t("chat:gemini_setup_validating"),
    stageFormat: t("chat:gemini_stage_format"),
    stageReach: t("chat:gemini_stage_reach"),
    stageVideo: t("chat:gemini_stage_video"),
    saved: t("chat:gemini_setup_saved"),
    keyHelp: t("chat:gemini_setup_key_help")
  }

  return (
    <CredentialCard
      connected={set}
      description={
        <>
          {t('credential_cards.gemini_description')}{" "}
          <a
            className="font-medium text-terracotta-700 dark:text-terracotta-300 underline hover:text-terracotta-600"
            href="https://aistudio.google.com/apikey"
            rel="noreferrer"
            target="_blank"
          >
            aistudio.google.com/apikey
          </a>{" "}
          {t('credential_cards.gemini_description_suffix')}
        </>
      }
      error={actions.error}
      headingRef={headingRef}
      testId="credential-card-gemini"
      title={t('credential_cards.gemini_title')}
    >
      {set ? (
        <div className="space-y-3">
          <p className="text-sm text-gray-700 dark:text-gray-300">{t('credential_cards.gemini_summary')}</p>
          <CredentialTestResultLine result={actions.testResult} />
          <div className="flex flex-wrap gap-2">
            <TestButton actions={actions} credential="gemini_api_key" />
            <button className={secondaryButtonClass()} onClick={() => setSheetOpen(true)} type="button">
              {t('credential_cards.gemini_replace')}
            </button>
            <ClearButton actions={actions} credential="gemini_api_key" />
          </div>
        </div>
      ) : (
        <button className={primaryButtonClass()} onClick={() => setSheetOpen(true)} type="button">
          {t('credential_cards.gemini_set_up')}
        </button>
      )}

      {sheetOpen ? (
        <GeminiSetupSheet
          labels={sheetLabels}
          onClose={() => {
            setSheetOpen(false)
            // The sheet held focus; hand it back into the card instead of body.
            focusHeading()
          }}
          onConfigured={() => {
            setSheetOpen(false)
            actions.setTestResult(undefined)
            onNotice(t("chat:gemini_setup_saved"))
            focusHeading()
          }}
        />
      ) : null}
    </CredentialCard>
  )
}
