import { inputClass } from "../lib/formClasses"
import { routePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { useLocation } from "react-router-dom"
import i18n from "../i18n"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  cacheCredentials,
  ClaudeCredentialCard,
  CodexCredentialCard,
  GeminiCredentialCard,
  GithubCredentialCard
} from "../components/credentials/CredentialCard"
import {
  fetchCredentials,
  revokeApiToken,
  rotateApiToken,
  savePartialCredentials,
  updateCredentials,
  type CredentialsInput,
  type CredentialsPayload
} from "../api/credentials"
import { errorMessage } from "../lib/errorMessage"
import { PanelMessage } from "../components/PanelMessage"

const queryKey = ["credentials"] as const
type AccountSettingsSection = "profile" | "credentials" | "agent" | "preferences"

export function CredentialsRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description="Encrypted provider and GitHub credentials for Syrus runs." label="Credentials" section="credentials" />
}

export function AccountProfileRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description="Your public team profile details." label="Profile" section="profile" />
}

export function AgentSettingsRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description="Default agent behavior for new Syrus work." label="Agent Settings" section="agent" />
}

export function PreferencesRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description="Account-level behavior preferences." label="Preferences" section="preferences" />
}

function AccountSettingsPage({ description, label, section }: { description: string; label: string; section: AccountSettingsSection }) {
  const { t } = useT("settings")
  usePageTitle(label)
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label={label} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{label}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{description}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <CredentialsAccountPanel onNotice={setNotice} section={section} />
    </main>
  )
}

function CredentialsAccountPanel({ onNotice, section }: { onNotice: (message: string | null) => void; section: AccountSettingsSection }) {
  const { t } = useT("settings")
  const credentials = useQuery({
    queryKey,
    queryFn: fetchCredentials
  })

  useEffect(() => {
    if (credentials.data?.message) onNotice(credentials.data.message)
  }, [credentials.data?.message, onNotice])

  return (
    <>
      {credentials.isPending ? <PanelMessage>{t('account_settings.loading_credentials')}</PanelMessage> : null}
      {credentials.isError ? <CredentialsError error={credentials.error} /> : null}
      {credentials.isSuccess ? <CredentialsView onNotice={onNotice} payload={credentials.data} section={section} /> : null}
    </>
  )
}

function CredentialsView({ payload, onNotice, section }: { payload: CredentialsPayload; onNotice: (message: string | null) => void; section: AccountSettingsSection }) {
  const { t } = useT("settings")
  const location = useLocation()
  const setupStatus = useSetupStatus()
  const prefix = routePrefix(location.pathname)

  if (section === "credentials") {
    return (
      <>
        {setupStatus && !setupStatus.first_successful_job_completed ? (
          <OnboardingEmptyState
            fallbackDescription="Save the GitHub and agent credentials Syrus should use, then continue to repository setup."
            fallbackTitle="Finish setup"
            prefix={prefix}
            setupStatus={setupStatus}
          />
        ) : null}
        {/* One card per provider, each owning its own state, actions, and
            errors — the same guided components the setup flow uses. */}
        <GithubCredentialCard onNotice={onNotice} payload={payload} />
        <ClaudeCredentialCard onNotice={onNotice} payload={payload} />
        <CodexCredentialCard onNotice={onNotice} payload={payload} />
        <GeminiCredentialCard onNotice={onNotice} payload={payload} />
        {payload.options.chat_providers.length > 0 ? <ChatProviderPanel onNotice={onNotice} payload={payload} /> : null}
        {payload.user.admin ? <ApiTokenPanel onNotice={onNotice} payload={payload} /> : null}
      </>
    )
  }

  return <CredentialsForm onNotice={onNotice} payload={payload} section={section} />
}

// Chat provider pick, saved immediately per-change (partial PATCH) — the
// credentials page no longer has a global Save.
function ChatProviderPanel({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const chatProvider = payload.user.chat_provider || ""
  const save = useMutation({
    mutationFn: (provider: string) => savePartialCredentials({ chat_provider: provider }),
    onSuccess: (updated) => {
      // cacheCredentials strips the server's generic "Credentials updated."
      // message before caching, so the payload-message effect cannot
      // overwrite the specific notice below, and refetches to reconcile
      // concurrent partial saves.
      cacheCredentials(queryClient, updated)
      onNotice(t('credential_cards.chat_provider_saved_notice'))
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t('credential_cards.chat_provider_heading')}</h2>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t('credential_cards.chat_provider_desc')}</p>
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save credentials.")}</PanelMessage> : null}
      <select
        aria-label={t('credential_cards.chat_provider_heading')}
        className={`mt-3 ${inputClass()}`}
        disabled={save.isPending}
        onChange={(event) => save.mutate(event.target.value)}
        value={payload.options.chat_providers.includes(chatProvider) ? chatProvider : ""}
      >
        <option disabled value="">{t('account_settings.select_provider')}</option>
        {payload.options.chat_providers.map((provider) => <option key={provider} value={provider}>{titleize(provider)}</option>)}
      </select>
    </section>
  )
}

function CredentialsForm({ payload, onNotice, section }: { payload: CredentialsPayload; onNotice: (message: string | null) => void; section: AccountSettingsSection }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [values, setValues] = useState<CredentialsInput>(inputFromPayload(payload))
  const roleOptions = payload.options.roles || ["developer", "product_owner"]
  const save = useMutation({
    mutationFn: () => updateCredentials(values),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setValues(inputFromPayload(updated))
      onNotice(updated.message || "Credentials updated.")
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

  const selectedAutoApprove = payload.options.auto_approve_modes.find((option) => option.value === values.auto_approve_mode)

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <form className="space-y-5" onSubmit={submit}>
        {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save credentials.")}</PanelMessage> : null}

        {section === "profile" ? (
          <>
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

            <Field label="Role">
              <select className={inputClass()} onChange={(event) => setValues({ ...values, role: event.target.value })} value={values.role}>
                {roleOptions.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
              </select>
            </Field>

            <Field label="Avatar URL">
              <input className={inputClass()} maxLength={500} onChange={(event) => setValues({ ...values, avatar_url: event.target.value })} type="url" value={values.avatar_url} />
            </Field>

            <Field label="Profile bio">
              <textarea className={inputClass()} maxLength={1000} onChange={(event) => setValues({ ...values, profile_bio: event.target.value })} rows={4} value={values.profile_bio} />
            </Field>
          </>
        ) : null}

        {section === "agent" ? (
          <Field label="Agent provider">
            <select className={inputClass()} onChange={(event) => setValues({ ...values, agent_provider: event.target.value })} value={values.agent_provider}>
              {payload.options.agent_providers.map((provider) => <option key={provider} value={provider}>{titleize(provider)}</option>)}
            </select>
          </Field>
        ) : null}

        {section === "agent" ? (
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
        ) : null}

        {section === "preferences" ? (
          <Field label="Language">
            <select
              className={inputClass()}
              onChange={(event) => {
                const locale = event.target.value
                setValues({ ...values, locale })
                i18n.changeLanguage(locale)
              }}
              value={values.locale}
            >
              <option value="en">{t('account_settings.lang_english')}</option>
              <option value="de">{t('account_settings.lang_deutsch')}</option>
              <option value="la">{t('account_settings.lang_latina')}</option>
            </select>
          </Field>
        ) : null}

        {section === "preferences" ? (
          <label className="flex items-start gap-3 text-sm">
            <input
              aria-label={t('account_settings.aria_pause_scheduling')}
              checked={values.scheduling_paused}
              className="mt-1 rounded border-gray-400"
              onChange={(event) => setValues({ ...values, scheduling_paused: event.target.checked })}
              type="checkbox"
            />
            <span>
              <span className="block font-medium text-gray-700 dark:text-gray-300">{t('account_settings.pause_scheduling')}</span>
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t('account_settings.pause_scheduling_desc')}</span>
            </span>
          </label>
        ) : null}

        {section === "agent" ? (
          <Field label="Auto-approval fallback">
            <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
              {payload.options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{selectedAutoApprove?.preview}</p>
          </Field>
        ) : null}

        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
          {save.isPending ? "Saving..." : "Save"}
        </button>
      </form>
    </section>
  )
}

function ApiTokenPanel({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
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
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t('account_settings.api_token_heading')}</h2>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t('account_settings.api_token_desc')}</p>

      {newToken ? (
        <div className="mt-3 rounded border border-emerald-200 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-950/40 p-3">
          <div className="text-xs font-medium uppercase text-emerald-700 dark:text-emerald-300">{t('account_settings.new_token')}</div>
          <code className="mt-1 block break-all font-mono text-sm">{newToken}</code>
        </div>
      ) : payload.credential_status.api_token ? (
        <p className="mt-3 text-xs text-gray-500 dark:text-gray-400">{t('account_settings.token_is_set')}</p>
      ) : (
        <p className="mt-3 text-xs text-amber-600 dark:text-amber-300">{t('account_settings.no_token')}</p>
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
            {t('account_settings.revoke')}
          </button>
        ) : null}
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  const { t } = useT("settings")
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function CredentialsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load credentials.")}</PanelMessage>
}


function inputFromPayload(payload: CredentialsPayload): CredentialsInput {
  const chatProvider = payload.user.chat_provider || ""

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
    role: payload.user.role,
    agent_provider: payload.user.agent_provider,
    chat_provider: payload.options.chat_providers.includes(chatProvider) ? chatProvider : "",
    claude_oauth_token: "",
    codex_auth_mode: payload.user.codex_auth_mode,
    codex_api_key: "",
    codex_auth_json: "",
    gemini_api_key: "",
    github_token: "",
    agent_max_turns: payload.user.agent_max_turns,
    scheduling_paused: payload.user.scheduling_paused,
    auto_approve_mode: payload.user.auto_approve_mode,
    locale: payload.user.locale
  }
}

function titleize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}


