import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { createConsumer } from "@rails/actioncable"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { useLocation } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  clearCredential,
  exchangeClaudeOauth,
  exchangeCodexOauth,
  fetchCredentials,
  revokeApiToken,
  rotateApiToken,
  startClaudeOauth,
  startCodexOauth,
  testCredential,
  updateCredentials,
  type CredentialTestResult,
  type CredentialsInput,
  type CredentialsPayload
} from "../api/credentials"

const queryKey = ["credentials"] as const

export function CredentialsRoute() {
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label="My credentials" className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">My credentials</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">Encrypted credentials and account settings for Syrus runs.</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <CredentialsAccountPanel onNotice={setNotice} />
    </main>
  )
}

function CredentialsAccountPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const credentials = useQuery({
    queryKey,
    queryFn: fetchCredentials
  })

  useEffect(() => {
    if (credentials.data?.message) onNotice(credentials.data.message)
  }, [credentials.data?.message, onNotice])

  return (
    <>
      {credentials.isPending ? <PanelMessage>Loading credentials...</PanelMessage> : null}
      {credentials.isError ? <CredentialsError error={credentials.error} /> : null}
      {credentials.isSuccess ? <CredentialsView onNotice={onNotice} payload={credentials.data} /> : null}
    </>
  )
}

function CredentialsView({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const location = useLocation()
  const setupStatus = useSetupStatus()
  const prefix = routePrefix(location.pathname)

  return (
    <>
      <GithubCredentialGuide />
      {setupStatus && !setupStatus.first_successful_job_completed ? (
        <OnboardingEmptyState
          fallbackDescription="Save the GitHub and agent credentials Syrus should use, then continue to repository setup."
          fallbackTitle="Finish setup"
          prefix={prefix}
          setupStatus={setupStatus}
        />
      ) : null}
      <CredentialsForm onNotice={onNotice} payload={payload} />
      {payload.user.admin ? <ApiTokenPanel onNotice={onNotice} payload={payload} /> : null}
    </>
  )
}

function GithubCredentialGuide() {
  return (
    <section className="rounded border border-blue-100 dark:border-blue-900/60 bg-blue-50 dark:bg-blue-950/40 p-4 text-sm text-blue-950 dark:text-blue-100">
      <h2 className="font-medium">GitHub access</h2>
      <p className="mt-1">
        A personal access token is the fallback credential for repositories without an active Syrus GitHub App installation. If an admin registers and installs the App on a repository, Syrus uses the App for that repository instead.
      </p>
      <p className="mt-1 text-xs text-blue-800 dark:text-blue-200">
        Keep a PAT configured for PAT-only repositories and GitHub owner/repository pickers.
      </p>
    </section>
  )
}

function CredentialsForm({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [values, setValues] = useState<CredentialsInput>(inputFromPayload(payload))
  const [testResults, setTestResults] = useState<Record<string, CredentialTestResult>>({})
  const [codexOauthCode, setCodexOauthCode] = useState("")
  const [codexOauthStarted, setCodexOauthStarted] = useState(false)
  const [codexOauthAutoConnecting, setCodexOauthAutoConnecting] = useState(false)
  const [codexOauthPopupBlocked, setCodexOauthPopupBlocked] = useState<string | null>(null)
  const save = useMutation({
    mutationFn: () => updateCredentials(values),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setValues(inputFromPayload(updated))
      setTestResults({})
      onNotice(updated.message || "Credentials updated.")
    }
  })
  const clear = useMutation({
    mutationFn: (credential: string) => clearCredential(credential),
    onSuccess: (updated, credential) => {
      queryClient.setQueryData(queryKey, updated)
      setValues(inputFromPayload(updated))
      setTestResults((current) => {
        const next = { ...current }
        delete next[credential]
        return next
      })
      onNotice(updated.message || "Credential cleared.")
    }
  })
  const test = useMutation({
    mutationFn: (credential: string) => testCredential(credential),
    onSuccess: (updated) => {
      setTestResults((current) => ({
        ...current,
        [updated.credential_test.credential]: updated.credential_test
      }))
      onNotice(updated.message || "Credential tested.")
    }
  })
  const startCodex = useMutation({
    mutationFn: startCodexOauth,
    onSuccess: (started) => {
      const tab = window.open(started.authorize_url, "_blank", "noopener,noreferrer")
      setCodexOauthPopupBlocked(tab ? null : started.authorize_url)
      setCodexOauthStarted(true)
      onNotice(null)
    }
  })
  const exchangeCodex = useMutation({
    mutationFn: (code?: string) => exchangeCodexOauth((code || codexOauthCode).trim()),
    onSuccess: async (updated) => {
      setTestResults((current) => ({
        ...current,
        [updated.credential_test.credential]: updated.credential_test
      }))
      await queryClient.invalidateQueries({ queryKey })
      setCodexOauthCode("")
      setCodexOauthAutoConnecting(false)
      onNotice(updated.message || "ChatGPT authorization saved.")
    },
    onError: () => {
      setCodexOauthAutoConnecting(false)
    }
  })
  const autoExchangeRef = useRef((code: string) => {
    setCodexOauthCode(code)
    setCodexOauthAutoConnecting(true)
    onNotice(null)
    exchangeCodex.mutate(code)
  })
  autoExchangeRef.current = (code: string) => {
    setCodexOauthCode(code)
    setCodexOauthAutoConnecting(true)
    onNotice(null)
    exchangeCodex.mutate(code)
  }

  useEffect(() => {
    setValues(inputFromPayload(payload))
  }, [payload])

  useEffect(() => {
    if (!codexOauthStarted) return

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
  }, [codexOauthStarted])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    save.mutate()
  }

  const codexSelected = values.agent_provider === "codex"
  const claudeSelected = values.agent_provider === "claude"
  const codexApiKeySelected = codexSelected && values.codex_auth_mode === "api_key"
  const codexAuthJsonSelected = codexSelected && values.codex_auth_mode === "chatgpt_login"
  const selectedAutoApprove = payload.options.auto_approve_modes.find((option) => option.value === values.auto_approve_mode)
  const testingCredential = test.variables

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <form className="space-y-5" onSubmit={submit}>
        {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save credentials.")}</PanelMessage> : null}
        {clear.isError ? <PanelMessage tone="error">{errorMessage(clear.error, "Unable to clear credential.")}</PanelMessage> : null}
        {test.isError ? <PanelMessage tone="error">{errorMessage(test.error, "Unable to test credential.")}</PanelMessage> : null}
        {startCodex.isError ? <PanelMessage tone="error">{errorMessage(startCodex.error, "Unable to start ChatGPT authorization.")}</PanelMessage> : null}
        {exchangeCodex.isError ? <PanelMessage tone="error">{errorMessage(exchangeCodex.error, "Unable to exchange ChatGPT authorization code.")}</PanelMessage> : null}

        <Field label="Display name">
          <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="First name">
            <input className={inputClass()} maxLength={80} onChange={(event) => setValues({ ...values, first_name: event.target.value })} type="text" value={values.first_name} />
          </Field>

          <Field label="Last name">
            <input className={inputClass()} maxLength={80} onChange={(event) => setValues({ ...values, last_name: event.target.value })} type="text" value={values.last_name} />
          </Field>
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Company">
            <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_company: event.target.value })} type="text" value={values.profile_company} />
          </Field>

          <Field label="Location">
            <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_location: event.target.value })} type="text" value={values.profile_location} />
          </Field>
        </div>

        <Field label="Website">
          <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_website: event.target.value })} type="url" value={values.profile_website} />
        </Field>

        <Field label="GitHub handle">
          <input className={inputClass()} maxLength={100} onChange={(event) => setValues({ ...values, github_handle: event.target.value })} type="text" value={values.github_handle} />
        </Field>

        <Field label="Avatar URL">
          <input className={inputClass()} maxLength={500} onChange={(event) => setValues({ ...values, avatar_url: event.target.value })} type="url" value={values.avatar_url} />
        </Field>

        <Field label="Profile bio">
          <textarea className={inputClass()} maxLength={1000} onChange={(event) => setValues({ ...values, profile_bio: event.target.value })} rows={4} value={values.profile_bio} />
        </Field>

        <Field label="Agent provider">
          <select className={inputClass()} onChange={(event) => setValues({ ...values, agent_provider: event.target.value })} value={values.agent_provider}>
            {payload.options.agent_providers.map((provider) => <option key={provider} value={provider}>{titleize(provider)}</option>)}
          </select>
        </Field>

        {claudeSelected ? (
          <SecretField
            clearPending={clear.isPending}
            description={
              <ClaudeTokenHelp
                onConnected={(result) => {
                  setTestResults((current) => ({ ...current, claude_oauth_token: result }))
                  onNotice(result.message || "Claude connected.")
                }}
              />
            }
            label="Claude OAuth token"
            name="claude_oauth_token"
            onChange={(value) => setValues({ ...values, claude_oauth_token: value })}
            onClear={() => clear.mutate("claude_oauth_token")}
            set={payload.credential_status.claude_oauth_token}
            testPending={test.isPending && testingCredential === "claude_oauth_token"}
            testResult={testResults.claude_oauth_token}
            unsaved={values.claude_oauth_token.trim().length > 0}
            onTest={() => test.mutate("claude_oauth_token")}
            value={values.claude_oauth_token}
          />
        ) : null}

        {codexSelected ? (
          <Field label="Codex authentication">
            <select className={inputClass()} onChange={(event) => setValues({ ...values, codex_auth_mode: event.target.value })} value={values.codex_auth_mode}>
              <option value="api_key">API key</option>
              <option value="chatgpt_login">ChatGPT auth.json</option>
            </select>
          </Field>
        ) : null}

        {codexApiKeySelected ? (
          <SecretField
            clearPending={clear.isPending}
            label="Codex API key"
            name="codex_api_key"
            onChange={(value) => setValues({ ...values, codex_api_key: value })}
            onClear={() => clear.mutate("codex_api_key")}
            set={payload.credential_status.codex_api_key}
            testPending={test.isPending && testingCredential === "codex_api_key"}
            testResult={testResults.codex_api_key}
            unsaved={values.codex_api_key.trim().length > 0}
            onTest={() => test.mutate("codex_api_key")}
            value={values.codex_api_key}
          />
        ) : null}

        {codexAuthJsonSelected ? (
          <CodexChatGptLogin
            authCode={codexOauthCode}
            authStarted={codexOauthStarted}
            autoConnecting={codexOauthAutoConnecting}
            clearPending={clear.isPending}
            exchangePending={exchangeCodex.isPending}
            manualValue={values.codex_auth_json}
            onAuthorize={() => startCodex.mutate()}
            onClear={() => clear.mutate("codex_auth_json")}
            onExchange={() => exchangeCodex.mutate(undefined)}
            onManualChange={(value) => setValues({ ...values, codex_auth_json: value })}
            onTest={() => test.mutate("codex_auth_json")}
            onCodeChange={setCodexOauthCode}
            popupBlockedUrl={codexOauthPopupBlocked}
            set={payload.credential_status.codex_auth_json}
            startPending={startCodex.isPending}
            testPending={test.isPending && testingCredential === "codex_auth_json"}
            testResult={testResults.codex_auth_json}
          />
        ) : null}

        <SecretField
          clearPending={clear.isPending}
          label="GitHub personal access token"
          name="github_token"
          onChange={(value) => setValues({ ...values, github_token: value })}
          onClear={() => clear.mutate("github_token")}
          set={payload.credential_status.github_token}
          testPending={test.isPending && testingCredential === "github_token"}
          testResult={testResults.github_token}
          unsaved={values.github_token.trim().length > 0}
          onTest={() => test.mutate("github_token")}
          value={values.github_token}
        />
        <p className="-mt-3 text-xs text-gray-500 dark:text-gray-400">
          Syrus uses a GitHub App installation when one is active for a repository owner. Repositories without an active installation use this PAT as the fallback credential.
        </p>

        <GithubRateLimit payload={payload} />

        <Field label="Max turns">
          <input
            className={inputClass()}
            max={payload.options.agent_max_turns.max}
            min={payload.options.agent_max_turns.min}
            onChange={(event) => setValues({ ...values, agent_max_turns: Number(event.target.value) })}
            type="number"
            value={values.agent_max_turns}
          />
        </Field>

        <label className="flex items-start gap-3 text-sm">
          <input
            checked={values.scheduling_paused}
            className="mt-1 rounded border-gray-400"
            onChange={(event) => setValues({ ...values, scheduling_paused: event.target.checked })}
            type="checkbox"
          />
          <span>
            <span className="block font-medium text-gray-700 dark:text-gray-300">Pause scheduling</span>
            <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">Prevents your scheduled tasks from firing automatically.</span>
          </span>
        </label>

        <Field label="Auto-approval fallback">
          <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
            {payload.options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{selectedAutoApprove?.preview}</p>
        </Field>

        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
          {save.isPending ? "Saving..." : "Save"}
        </button>
      </form>
    </section>
  )
}

function ClaudeTokenHelp({ onConnected }: { onConnected: (result: CredentialTestResult) => void }) {
  return (
    <div className="mt-3 space-y-3">
      <ClaudeOauthConnector onConnected={onConnected} />
      <p className="text-xs leading-5 text-gray-500 dark:text-gray-400">
        You can also run <code className="font-mono text-gray-700 dark:text-gray-300">claude setup-token</code> and paste the long-lived token it prints. Syrus stores this value and passes it as <code className="font-mono text-gray-700 dark:text-gray-300">CLAUDE_CODE_OAUTH_TOKEN</code> for Claude runs. Do not paste the short-lived token from Claude Code's local credential store. See the{" "}
        <a className="font-medium text-blue-700 dark:text-blue-300 underline hover:text-blue-600 dark:hover:text-blue-400" href="https://code.claude.com/docs/en/authentication#generate-a-long-lived-token" rel="noreferrer" target="_blank">
          Anthropic authentication docs
        </a>
        .
      </p>
    </div>
  )
}

function ClaudeOauthConnector({ onConnected }: { onConnected: (result: CredentialTestResult) => void }) {
  const queryClient = useQueryClient()
  const [authStarted, setAuthStarted] = useState(false)
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const [code, setCode] = useState("")
  const [starting, setStarting] = useState(false)
  const [exchanging, setExchanging] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [connected, setConnected] = useState<string | null>(null)

  async function authorize() {
    setError(null)
    setPopupBlocked(null)
    setStarting(true)
    try {
      const { authorize_url } = await startClaudeOauth()
      const tab = window.open(authorize_url, "_blank", "noopener,noreferrer")
      if (!tab) setPopupBlocked(authorize_url)
      setAuthStarted(true)
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not start Claude authorization.")
    } finally {
      setStarting(false)
    }
  }

  async function connect() {
    if (code.trim().length === 0) {
      setError("Paste the code from Claude first.")
      return
    }

    setError(null)
    setExchanging(true)
    try {
      const payload = await exchangeClaudeOauth(code.trim())
      if (payload.credential_test.ok) {
        await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
        await queryClient.invalidateQueries({ queryKey })
        setCode("")
        setConnected(payload.credential_test.message || "Claude connected.")
        onConnected(payload.credential_test)
      } else {
        setError(payload.credential_test.message || "The token Claude returned did not work. Try again.")
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Could not exchange the code. Try authorizing again.")
    } finally {
      setExchanging(false)
    }
  }

  return (
    <div className="rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-950/40 p-3 text-xs text-gray-600 dark:text-gray-400">
      <p>
        Authorize with Claude, copy the code Claude shows, then paste it here to save a durable OAuth token for Syrus runs.
      </p>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <button
          className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-blue-300 dark:disabled:bg-blue-900"
          disabled={starting}
          onClick={authorize}
          type="button"
        >
          {starting ? "Opening..." : authStarted ? "Reopen Claude authorization" : "Authorize with Claude"}
        </button>
        <input
          aria-label="Authorization code from Claude"
          autoComplete="off"
          className="min-w-0 flex-1 rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 font-mono text-sm text-gray-900 dark:text-gray-100 shadow-sm focus:outline-blue-600 disabled:bg-gray-100 dark:disabled:bg-gray-800"
          disabled={!authStarted}
          onChange={(event) => setCode(event.target.value)}
          placeholder="paste code here"
          spellCheck={false}
          type="text"
          value={code}
        />
        <button
          className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-white dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600"
          disabled={!authStarted || exchanging || code.trim().length === 0}
          onClick={connect}
          type="button"
        >
          {exchanging ? "Connecting..." : "Connect"}
        </button>
      </div>
      {popupBlocked ? (
        <p className="mt-2 text-amber-700 dark:text-amber-300">
          Popup blocked.{" "}
          <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
            Open the authorization page
          </a>{" "}
          manually.
        </p>
      ) : null}
      {connected ? <p className="mt-2 text-emerald-700 dark:text-emerald-300">{connected}</p> : null}
      {error ? <p className="mt-2 text-red-700 dark:text-red-300">{error}</p> : null}
    </div>
  )
}

function CodexChatGptLogin({
  authCode,
  authStarted,
  autoConnecting,
  manualValue,
  set,
  popupBlockedUrl,
  startPending,
  exchangePending,
  clearPending,
  testPending,
  testResult,
  onAuthorize,
  onExchange,
  onCodeChange,
  onManualChange,
  onClear,
  onTest
}: {
  authCode: string
  authStarted: boolean
  autoConnecting: boolean
  manualValue: string
  set: boolean
  popupBlockedUrl: string | null
  startPending: boolean
  exchangePending: boolean
  clearPending: boolean
  testPending: boolean
  testResult?: CredentialTestResult
  onAuthorize: () => void
  onExchange: () => void
  onCodeChange: (value: string) => void
  onManualChange: (value: string) => void
  onClear: () => void
  onTest: () => void
}) {
  const manualUnsaved = manualValue.trim().length > 0
  const exchangeDisabled = exchangePending || authCode.trim().length === 0

  return (
    <div className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      <div>Codex ChatGPT login</div>
      <StatusLine set={set} />
      <div className="mt-3 space-y-3 rounded border border-gray-200 dark:border-gray-700 p-3">
        <div className="flex flex-wrap items-center gap-2">
          <button
            className="rounded bg-gray-900 dark:bg-gray-100 px-3 py-2 text-sm font-medium text-white dark:text-gray-900 hover:bg-gray-800 dark:hover:bg-white disabled:cursor-not-allowed disabled:bg-gray-300 dark:disabled:bg-gray-700"
            disabled={startPending}
            onClick={onAuthorize}
            type="button"
          >
            {startPending ? "Opening..." : "Authorize with ChatGPT"}
          </button>
          {set ? (
            <button className="rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:text-red-300 dark:disabled:text-red-500" disabled={clearPending} onClick={onClear} type="button">
              Clear
            </button>
          ) : null}
          <button className="rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={!set || manualUnsaved || testPending} onClick={onTest} type="button">
            {testPending ? "Testing..." : "Test"}
          </button>
        </div>
        {popupBlockedUrl ? (
          <p className="text-xs text-amber-600 dark:text-amber-300">
            Popup blocked.{" "}
            <a className="font-medium underline" href={popupBlockedUrl} rel="noreferrer" target="_blank">
              Open authorization
            </a>
            .
          </p>
        ) : null}
        {autoConnecting ? (
          <p className="text-xs text-gray-500 dark:text-gray-400">Connecting...</p>
        ) : null}
        <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
          <input
            aria-label="ChatGPT authorization code"
            autoComplete="off"
            className={inputClass()}
            onChange={(event) => onCodeChange(event.target.value)}
            placeholder={authStarted ? "Copy the full redirect URL from your browser's address bar and paste it here." : "Authorize first, then paste the redirect URL"}
            type="text"
            value={authCode}
          />
          <button
            className="rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600"
            disabled={exchangeDisabled}
            onClick={onExchange}
            type="button"
          >
            {exchangePending ? "Connecting..." : "Connect"}
          </button>
        </div>
        <CredentialTestLine result={testResult} unsaved={manualUnsaved} />
      </div>

      <details className="mt-3 rounded border border-gray-200 dark:border-gray-700 p-3">
        <summary className="cursor-pointer text-sm text-gray-700 dark:text-gray-300">Paste auth.json manually</summary>
        <div className="mt-3 space-y-2">
          <textarea aria-label="Codex ChatGPT auth.json" className={`${inputClass()} font-mono text-xs`} name="codex_auth_json" onChange={(event) => onManualChange(event.target.value)} rows={6} value={manualValue} />
          <p className="text-xs text-gray-500 dark:text-gray-400">Save after pasting a local Codex auth.json value.</p>
        </div>
      </details>
    </div>
  )
}

function SecretField({
  label,
  name,
  value,
  set,
  description,
  clearPending,
  testPending,
  testResult,
  unsaved,
  onChange,
  onClear,
  onTest
}: {
  label: string
  name: string
  value: string
  set: boolean
  description?: ReactNode
  clearPending: boolean
  testPending: boolean
  testResult?: CredentialTestResult
  unsaved: boolean
  onChange: (value: string) => void
  onClear: () => void
  onTest: () => void
}) {
  return (
    <Field label={label}>
      <StatusLine set={set} />
      <div className="mt-2 flex gap-2">
        <input aria-label={label} autoComplete="off" className={inputClass()} name={name} onChange={(event) => onChange(event.target.value)} type="password" value={value} />
        <button className="rounded border border-gray-300 dark:border-gray-600 px-3 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={!set || unsaved || testPending} onClick={onTest} type="button">
          {testPending ? "Testing..." : "Test"}
        </button>
        {set ? (
          <button className="rounded border border-gray-300 dark:border-gray-600 px-3 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:text-red-300 dark:disabled:text-red-500" disabled={clearPending} onClick={onClear} type="button">
            Clear
          </button>
        ) : null}
      </div>
      {description}
      <CredentialTestLine result={testResult} unsaved={unsaved} />
    </Field>
  )
}

function SecretTextArea({
  label,
  name,
  value,
  set,
  clearPending,
  testPending,
  testResult,
  unsaved,
  onChange,
  onClear,
  onTest
}: {
  label: string
  name: string
  value: string
  set: boolean
  clearPending: boolean
  testPending: boolean
  testResult?: CredentialTestResult
  unsaved: boolean
  onChange: (value: string) => void
  onClear: () => void
  onTest: () => void
}) {
  return (
    <Field label={label}>
      <StatusLine set={set} />
      <div className="mt-2 space-y-2">
        <textarea aria-label={label} className={`${inputClass()} font-mono text-xs`} name={name} onChange={(event) => onChange(event.target.value)} rows={6} value={value} />
        <div className="flex gap-2">
          <button className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 disabled:text-gray-300 dark:disabled:text-gray-600" disabled={!set || unsaved || testPending} onClick={onTest} type="button">
            {testPending ? "Testing..." : "Test"}
          </button>
          {set ? (
            <button className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:text-red-300 dark:disabled:text-red-500" disabled={clearPending} onClick={onClear} type="button">
              Clear
            </button>
          ) : null}
        </div>
      </div>
      <CredentialTestLine result={testResult} unsaved={unsaved} />
    </Field>
  )
}

function ApiTokenPanel({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [newToken, setNewToken] = useState(payload.new_api_token || "")
  const rotate = useMutation({
    mutationFn: rotateApiToken,
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNewToken(updated.new_api_token || "")
      onNotice(updated.message || "API token rotated.")
    }
  })
  const revoke = useMutation({
    mutationFn: revokeApiToken,
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNewToken("")
      onNotice(updated.message || "API token revoked.")
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">API token</h2>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">Admin token for `/api/v1/admin/*` automation. Plaintext is shown once after rotation.</p>

      {newToken ? (
        <div className="mt-3 rounded border border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 p-3">
          <div className="text-xs font-medium uppercase text-emerald-700 dark:text-emerald-300">New token</div>
          <code className="mt-1 block break-all font-mono text-sm">{newToken}</code>
        </div>
      ) : payload.credential_status.api_token ? (
        <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">A token is set.</p>
      ) : (
        <p className="mt-3 text-xs text-amber-600 dark:text-amber-300">No token issued yet.</p>
      )}

      {rotate.isError ? <PanelMessage tone="error">{errorMessage(rotate.error, "Unable to rotate API token.")}</PanelMessage> : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, "Unable to revoke API token.")}</PanelMessage> : null}

      <div className="mt-3 flex gap-2">
        <button
          className="rounded bg-gray-200 dark:bg-gray-700 px-3 py-1.5 text-sm font-medium text-gray-800 dark:text-gray-200 hover:bg-gray-300 disabled:bg-gray-100 dark:disabled:bg-gray-800"
          disabled={rotate.isPending}
          onClick={() => {
            if (!payload.credential_status.api_token || window.confirm("Rotate the API token? Existing scripts using the old token will stop working immediately.")) {
              rotate.mutate()
            }
          }}
          type="button"
        >
          {payload.credential_status.api_token ? "Rotate token" : "Generate token"}
        </button>
        {payload.credential_status.api_token ? (
          <button
            className="rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:text-red-300 dark:disabled:text-red-500"
            disabled={revoke.isPending}
            onClick={() => {
              if (window.confirm("Revoke the API token? All API calls using it will start returning 401.")) revoke.mutate()
            }}
            type="button"
          >
            Revoke
          </button>
        ) : null}
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function StatusLine({ set }: { set: boolean }) {
  return set ? (
    <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">Currently set. Submit a new value to replace.</p>
  ) : (
    <p className="mt-1 text-xs text-amber-600 dark:text-amber-300">Not set.</p>
  )
}

function CredentialTestLine({ result, unsaved }: { result?: CredentialTestResult; unsaved: boolean }) {
  if (unsaved) {
    return <p className="mt-2 text-xs text-amber-600 dark:text-amber-300">Save changes before testing this credential.</p>
  }

  if (!result) return null

  const scopes = result.details.scopes || []
  const suffix = scopes.length > 0 ? ` Scopes: ${scopes.join(", ")}.` : ""
  return (
    <p className={`mt-2 text-xs ${result.ok ? "text-emerald-700 dark:text-emerald-300" : "text-red-700 dark:text-red-300"}`}>
      <span aria-hidden="true">{result.ok ? "✅" : "❌"}</span> {result.message}{suffix}
    </p>
  )
}

function GithubRateLimit({ payload }: { payload: CredentialsPayload }) {
  if (!payload.github_rate_limit) {
    return <p className="text-xs text-gray-400 dark:text-gray-500">GitHub quota not yet recorded.</p>
  }

  return (
    <p className="text-xs text-gray-500 dark:text-gray-400">
      GitHub API quota: <strong>{payload.github_rate_limit.remaining}</strong> / {payload.github_rate_limit.limit} remaining ({payload.github_rate_limit.resource} bucket).
    </p>
  )
}

function CredentialsError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load credentials.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    success: "border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 shadow-sm focus:outline-blue-600"
}

function inputFromPayload(payload: CredentialsPayload): CredentialsInput {
  return {
    name: payload.user.name || "",
    first_name: payload.user.first_name || "",
    last_name: payload.user.last_name || "",
    profile_location: payload.user.profile_location || "",
    profile_company: payload.user.profile_company || "",
    profile_website: payload.user.profile_website || "",
    github_handle: payload.user.github_handle || "",
    profile_bio: payload.user.profile_bio || "",
    avatar_url: payload.user.avatar_url || "",
    agent_provider: payload.user.agent_provider,
    claude_oauth_token: "",
    codex_auth_mode: payload.user.codex_auth_mode,
    codex_api_key: "",
    codex_auth_json: "",
    github_token: "",
    agent_max_turns: payload.user.agent_max_turns,
    scheduling_paused: payload.user.scheduling_paused,
    auto_approve_mode: payload.user.auto_approve_mode
  }
}

function titleize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}
