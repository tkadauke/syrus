import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { useLocation } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  clearCredential,
  fetchCredentials,
  revokeApiToken,
  rotateApiToken,
  updateCredentials,
  type CredentialsInput,
  type CredentialsPayload
} from "../api/credentials"

const queryKey = ["credentials"] as const

export function CredentialsRoute() {
  const credentials = useQuery({
    queryKey,
    queryFn: fetchCredentials
  })

  return (
    <main aria-label="My credentials" className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900">My credentials</h1>
        <p className="mt-1 text-sm text-gray-600">Encrypted credentials and account settings for Syrus runs.</p>
      </header>

      {credentials.isPending ? <PanelMessage>Loading credentials...</PanelMessage> : null}
      {credentials.isError ? <CredentialsError error={credentials.error} /> : null}
      {credentials.isSuccess ? <CredentialsView payload={credentials.data} /> : null}
    </main>
  )
}

function CredentialsView({ payload }: { payload: CredentialsPayload }) {
  const location = useLocation()
  const setupStatus = useSetupStatus()
  const prefix = routePrefix(location.pathname)
  const [notice, setNotice] = useState<string | null>(payload.message || null)

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <GithubCredentialGuide />
      {setupStatus && !setupStatus.first_successful_job_completed ? (
        <OnboardingEmptyState
          fallbackDescription="Save the GitHub and agent credentials Syrus should use, then continue to repository setup."
          fallbackTitle="Finish setup"
          prefix={prefix}
          setupStatus={setupStatus}
        />
      ) : null}
      <CredentialsForm onNotice={setNotice} payload={payload} />
      {payload.user.admin ? <ApiTokenPanel onNotice={setNotice} payload={payload} /> : null}
    </>
  )
}

function GithubCredentialGuide() {
  return (
    <section className="rounded border border-blue-100 bg-blue-50 p-4 text-sm text-blue-950">
      <h2 className="font-medium">GitHub access</h2>
      <p className="mt-1">
        A personal access token is the fallback credential for repositories without an active Syrus GitHub App installation. If an admin registers and installs the App on a repository, Syrus uses the App for that repository instead.
      </p>
      <p className="mt-1 text-xs text-blue-800">
        Keep a PAT configured for PAT-only repositories and GitHub owner/repository pickers.
      </p>
    </section>
  )
}

function CredentialsForm({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [values, setValues] = useState<CredentialsInput>(inputFromPayload(payload))
  const save = useMutation({
    mutationFn: () => updateCredentials(values),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setValues(inputFromPayload(updated))
      onNotice(updated.message || "Credentials updated.")
    }
  })
  const clear = useMutation({
    mutationFn: (credential: string) => clearCredential(credential),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setValues(inputFromPayload(updated))
      onNotice(updated.message || "Credential cleared.")
    }
  })

  useEffect(() => {
    setValues(inputFromPayload(payload))
  }, [payload])

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

  return (
    <section className="rounded border border-gray-200 bg-white p-5">
      <form className="space-y-5" onSubmit={submit}>
        {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save credentials.")}</PanelMessage> : null}
        {clear.isError ? <PanelMessage tone="error">{errorMessage(clear.error, "Unable to clear credential.")}</PanelMessage> : null}

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

        <Field label="Bio">
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
            label="Claude OAuth token"
            name="claude_oauth_token"
            onChange={(value) => setValues({ ...values, claude_oauth_token: value })}
            onClear={() => clear.mutate("claude_oauth_token")}
            set={payload.credential_status.claude_oauth_token}
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
            value={values.codex_api_key}
          />
        ) : null}

        {codexAuthJsonSelected ? (
          <SecretTextArea
            clearPending={clear.isPending}
            label="Codex ChatGPT auth.json"
            name="codex_auth_json"
            onChange={(value) => setValues({ ...values, codex_auth_json: value })}
            onClear={() => clear.mutate("codex_auth_json")}
            set={payload.credential_status.codex_auth_json}
            value={values.codex_auth_json}
          />
        ) : null}

        <SecretField
          clearPending={clear.isPending}
          label="GitHub personal access token"
          name="github_token"
          onChange={(value) => setValues({ ...values, github_token: value })}
          onClear={() => clear.mutate("github_token")}
          set={payload.credential_status.github_token}
          value={values.github_token}
        />
        <p className="-mt-3 text-xs text-gray-500">
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
            <span className="block font-medium text-gray-700">Pause scheduling</span>
            <span className="mt-1 block text-xs text-gray-500">Prevents your scheduled tasks from firing automatically.</span>
          </span>
        </label>

        <Field label="Auto-approval fallback">
          <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
            {payload.options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
          </select>
          <p className="mt-1 text-xs text-gray-500">{selectedAutoApprove?.preview}</p>
        </Field>

        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300" disabled={save.isPending} type="submit">
          {save.isPending ? "Saving..." : "Save"}
        </button>
      </form>
    </section>
  )
}

function SecretField({
  label,
  name,
  value,
  set,
  clearPending,
  onChange,
  onClear
}: {
  label: string
  name: string
  value: string
  set: boolean
  clearPending: boolean
  onChange: (value: string) => void
  onClear: () => void
}) {
  return (
    <Field label={label}>
      <StatusLine set={set} />
      <div className="mt-2 flex gap-2">
        <input aria-label={label} autoComplete="off" className={inputClass()} name={name} onChange={(event) => onChange(event.target.value)} type="password" value={value} />
        {set ? (
          <button className="rounded border border-gray-300 px-3 text-sm text-red-700 hover:bg-red-50 disabled:text-red-300" disabled={clearPending} onClick={onClear} type="button">
            Clear
          </button>
        ) : null}
      </div>
    </Field>
  )
}

function SecretTextArea({
  label,
  name,
  value,
  set,
  clearPending,
  onChange,
  onClear
}: {
  label: string
  name: string
  value: string
  set: boolean
  clearPending: boolean
  onChange: (value: string) => void
  onClear: () => void
}) {
  return (
    <Field label={label}>
      <StatusLine set={set} />
      <div className="mt-2 space-y-2">
        <textarea aria-label={label} className={`${inputClass()} font-mono text-xs`} name={name} onChange={(event) => onChange(event.target.value)} rows={6} value={value} />
        {set ? (
          <button className="rounded border border-gray-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50 disabled:text-red-300" disabled={clearPending} onClick={onClear} type="button">
            Clear
          </button>
        ) : null}
      </div>
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
    <section className="rounded border border-gray-200 bg-white p-5">
      <h2 className="text-base font-semibold text-gray-900">API token</h2>
      <p className="mt-1 text-xs text-gray-500">Admin token for `/api/v1/admin/*` automation. Plaintext is shown once after rotation.</p>

      {newToken ? (
        <div className="mt-3 rounded border border-emerald-200 bg-emerald-50 p-3">
          <div className="text-xs font-medium uppercase text-emerald-700">New token</div>
          <code className="mt-1 block break-all font-mono text-sm">{newToken}</code>
        </div>
      ) : payload.credential_status.api_token ? (
        <p className="mt-3 text-xs text-gray-500">A token is set.</p>
      ) : (
        <p className="mt-3 text-xs text-amber-600">No token issued yet.</p>
      )}

      {rotate.isError ? <PanelMessage tone="error">{errorMessage(rotate.error, "Unable to rotate API token.")}</PanelMessage> : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, "Unable to revoke API token.")}</PanelMessage> : null}

      <div className="mt-3 flex gap-2">
        <button
          className="rounded bg-gray-200 px-3 py-1.5 text-sm font-medium text-gray-800 hover:bg-gray-300 disabled:bg-gray-100"
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
            className="rounded bg-red-50 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-100 disabled:text-red-300"
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
    <label className="block text-sm font-medium text-gray-700">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function StatusLine({ set }: { set: boolean }) {
  return set ? (
    <p className="mt-1 text-xs text-gray-500">Currently set. Submit a new value to replace.</p>
  ) : (
    <p className="mt-1 text-xs text-amber-600">Not set.</p>
  )
}

function GithubRateLimit({ payload }: { payload: CredentialsPayload }) {
  if (!payload.github_rate_limit) {
    return <p className="text-xs text-gray-400">GitHub quota not yet recorded.</p>
  }

  return (
    <p className="text-xs text-gray-500">
      GitHub API quota: <strong>{payload.github_rate_limit.remaining}</strong> / {payload.github_rate_limit.limit} remaining ({payload.github_rate_limit.resource} bucket).
    </p>
  )
}

function CredentialsError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load credentials.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
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
