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
  overrideProviderAvailability,
  revokeApiToken,
  rotateApiToken,
  savePartialCredentials,
  recheckProviderAvailability,
  updateCredentials,
  type CredentialsInput,
  type CredentialsPayload
} from "../api/credentials"
import { deleteJson } from "../api/client"
import { errorMessage } from "../lib/errorMessage"
import { PanelMessage } from "../components/PanelMessage"
import { useConfirm } from "../hooks/useConfirm"
import { deletePasskey, fetchPasskeyRegistrationOptions, fetchPasskeys, registerPasskey, type PasskeyRecord } from "../api/passkeys"
import { isPasskeySupported, registerNewPasskey } from "../lib/passkey"

const queryKey = ["credentials"] as const
type AccountSettingsSection = "profile" | "credentials" | "agent" | "preferences"

export function CredentialsRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description={t('account_settings.credentials_description')} label={t('nav.credentials')} section="credentials" />
}

export function AccountProfileRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description={t('account_settings.profile_description')} label={t('nav.profile')} section="profile" />
}

export function AgentSettingsRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description={t('account_settings.agent_settings_description')} label={t('nav.agent_settings')} section="agent" />
}

export function PreferencesRoute() {
  const { t } = useT("settings")
  return <AccountSettingsPage description={t('account_settings.preferences_description')} label={t('nav.preferences')} section="preferences" />
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
        <PasskeysPanel />
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

  const resetTours = useMutation({
    mutationFn: () => deleteJson("/api/v1/app/tours/reset"),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      onNotice(t('account_settings.reset_tours_notice'))
    }
  })
  const roleOptions = payload.options.roles || ["developer", "product_owner"]
  const sectionNoticeKey: Partial<Record<AccountSettingsSection, string>> = {
    preferences: "account_settings.preferences_saved_notice",
    profile: "account_settings.profile_saved_notice",
    agent: "account_settings.agent_settings_saved_notice",
  }
  const save = useMutation({
    mutationFn: () => updateCredentials(values),
    onSuccess: (updated) => {
      // cacheCredentials strips the server's generic "Credentials updated."
      // message before caching so the payload-message effect in
      // CredentialsAccountPanel cannot overwrite the section-specific notice.
      cacheCredentials(queryClient, updated)
      setValues(inputFromPayload(updated))
      const key = sectionNoticeKey[section]
      onNotice(key ? t(key) : (updated.message ?? ""))
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
            <Field label={t('account_settings.display_name')}>
              <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
            </Field>

            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('account_settings.first_name')}>
                <input className={inputClass()} maxLength={80} onChange={(event) => setValues({ ...values, first_name: event.target.value })} type="text" value={values.first_name} />
              </Field>

              <Field label={t('account_settings.last_name')}>
                <input className={inputClass()} maxLength={80} onChange={(event) => setValues({ ...values, last_name: event.target.value })} type="text" value={values.last_name} />
              </Field>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <Field label={t('account_settings.company')}>
                <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_company: event.target.value })} type="text" value={values.profile_company} />
              </Field>

              <Field label={t('account_settings.location')}>
                <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_location: event.target.value })} type="text" value={values.profile_location} />
              </Field>
            </div>

            <Field label={t('account_settings.website')}>
              <input className={inputClass()} onChange={(event) => setValues({ ...values, profile_website: event.target.value })} type="url" value={values.profile_website} />
            </Field>

            <Field label={t('account_settings.github_handle')}>
              <input className={inputClass()} maxLength={100} onChange={(event) => setValues({ ...values, github_handle: event.target.value })} type="text" value={values.github_handle} />
            </Field>

            <Field label={t('account_settings.role')}>
              <select className={inputClass()} onChange={(event) => setValues({ ...values, role: event.target.value })} value={values.role}>
                {roleOptions.map((role) => <option key={role} value={role}>{titleize(role)}</option>)}
              </select>
            </Field>

            <Field label={t('account_settings.avatar_url')}>
              <input className={inputClass()} maxLength={500} onChange={(event) => setValues({ ...values, avatar_url: event.target.value })} type="url" value={values.avatar_url} />
            </Field>

            <Field label={t('account_settings.profile_bio')}>
              <textarea className={inputClass()} maxLength={1000} onChange={(event) => setValues({ ...values, profile_bio: event.target.value })} rows={4} value={values.profile_bio} />
            </Field>
          </>
        ) : null}

        {section === "agent" ? (
          <Field label={t('account_settings.agent_provider')}>
            <select className={inputClass()} onChange={(event) => setValues({ ...values, agent_provider: event.target.value })} value={values.agent_provider}>
              {payload.options.agent_providers.map((provider) => <option key={provider} value={provider}>{titleize(provider)}</option>)}
            </select>
          </Field>
        ) : null}

        {section === "agent" ? (
          <Field label={t('account_settings.max_turns')}>
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

        {section === "agent" ? (
          <ProviderAvailabilitySettings
            onNotice={onNotice}
            payload={payload}
            setValues={setValues}
            values={values}
          />
        ) : null}

        {section === "preferences" ? (
          <Field label={t('account_settings.language')}>
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

        {section === "preferences" ? (
          <Field label={t('account_settings.reset_tours')}>
            <p className="mb-2 text-xs text-gray-500 dark:text-gray-400">{t('account_settings.reset_tours_desc')}</p>
            <button
              className="rounded bg-gray-100 dark:bg-gray-800 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:cursor-not-allowed disabled:opacity-50"
              disabled={resetTours.isPending}
              onClick={() => resetTours.mutate()}
              type="button"
            >
              {t('account_settings.reset_tours_button')}
            </button>
          </Field>
        ) : null}

        {section === "agent" ? (
          <Field label={t('account_settings.auto_approval_fallback')}>
            <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
              {payload.options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{selectedAutoApprove?.preview}</p>
          </Field>
        ) : null}

        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
          {save.isPending ? t('account_settings.saving') : t('account_settings.save')}
        </button>
      </form>
    </section>
  )
}

const passkeysQueryKey = ["passkeys"] as const

function PasskeysPanel() {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const { confirm, dialog } = useConfirm()
  const [adding, setAdding] = useState(false)
  const [nickname, setNickname] = useState("")
  const [addError, setAddError] = useState<string | null>(null)
  const [addPending, setAddPending] = useState(false)

  const passkeys = useQuery({
    queryKey: passkeysQueryKey,
    queryFn: fetchPasskeys
  })

  const remove = useMutation({
    mutationFn: (id: number) => deletePasskey(id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: passkeysQueryKey })
    }
  })

  async function handleAdd() {
    setAddError(null)
    setAddPending(true)
    try {
      await registerNewPasskey(nickname, fetchPasskeyRegistrationOptions, registerPasskey)
      setAdding(false)
      setNickname("")
      void queryClient.invalidateQueries({ queryKey: passkeysQueryKey })
    } catch (err) {
      if (err instanceof DOMException && err.name === "NotAllowedError") {
        // user cancelled — no error message
      } else {
        setAddError(errorMessage(err, t("account_settings.passkeys_add_error")))
      }
    } finally {
      setAddPending(false)
    }
  }

  async function handleRemove(passkey: PasskeyRecord) {
    if (await confirm({ message: t("account_settings.passkeys_confirm_remove"), destructive: true })) {
      remove.mutate(passkey.id)
    }
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("account_settings.passkeys_heading")}</h2>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("account_settings.passkeys_desc")}</p>

      {passkeys.isError ? <PanelMessage tone="error">{errorMessage(passkeys.error, t("account_settings.passkeys_load_error"))}</PanelMessage> : null}
      {remove.isError ? <PanelMessage tone="error">{errorMessage(remove.error, t("account_settings.passkeys_remove_error"))}</PanelMessage> : null}

      {passkeys.isSuccess && passkeys.data.length === 0 ? (
        <p className="mt-3 text-sm text-gray-500 dark:text-gray-400">{t("account_settings.passkeys_empty")}</p>
      ) : null}

      {passkeys.isSuccess && passkeys.data.length > 0 ? (
        <ul className="mt-3 divide-y divide-gray-100 dark:divide-gray-800">
          {passkeys.data.map((passkey) => (
            <li className="flex items-center justify-between gap-4 py-2" key={passkey.id}>
              <div className="min-w-0">
                <p className="text-sm font-medium text-gray-800 dark:text-gray-200 truncate">
                  {passkey.nickname || t("account_settings.passkeys_unnamed")}
                </p>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  {t("account_settings.passkeys_added")}: {new Date(passkey.created_at).toLocaleDateString()}
                  {passkey.last_used_at ? ` · ${t("account_settings.passkeys_last_used")}: ${new Date(passkey.last_used_at).toLocaleDateString()}` : ""}
                </p>
              </div>
              <button
                className="shrink-0 rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:opacity-50"
                disabled={remove.isPending}
                onClick={() => handleRemove(passkey)}
                type="button"
              >
                {t("account_settings.passkeys_remove")}
              </button>
            </li>
          ))}
        </ul>
      ) : null}

      {adding ? (
        <div className="mt-3 flex items-center gap-2">
          <input
            aria-label={t("account_settings.passkeys_nickname_label")}
            className={inputClass()}
            disabled={addPending}
            maxLength={100}
            onChange={(event) => setNickname(event.target.value)}
            placeholder={t("account_settings.passkeys_nickname_placeholder")}
            type="text"
            value={nickname}
          />
          <button
            className="shrink-0 rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
            disabled={addPending}
            onClick={handleAdd}
            type="button"
          >
            {addPending ? t("account_settings.passkeys_saving") : t("account_settings.passkeys_save")}
          </button>
          <button
            className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
            disabled={addPending}
            onClick={() => { setAdding(false); setNickname(""); setAddError(null) }}
            type="button"
          >
            {t("account_settings.passkeys_cancel")}
          </button>
        </div>
      ) : isPasskeySupported() ? (
        <button
          className="mt-3 rounded bg-gray-100 dark:bg-gray-800 px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700"
          onClick={() => { setAdding(true); setAddError(null) }}
          type="button"
        >
          {t("account_settings.passkeys_add")}
        </button>
      ) : null}

      {addError ? <PanelMessage tone="error">{addError}</PanelMessage> : null}
      {dialog}
    </section>
  )
}

function ApiTokenPanel({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [newToken, setNewToken] = useState(payload.new_api_token || "")
  const rotate = useMutation({
    mutationFn: rotateApiToken,
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNewToken(updated.new_api_token || "")
      onNotice(updated.message || t('account_settings.api_token_rotated'))
    }
  })
  const revoke = useMutation({
    mutationFn: revokeApiToken,
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNewToken("")
      onNotice(updated.message || t('account_settings.api_token_revoked'))
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
          onClick={async () => {
            if (!payload.credential_status.api_token || await confirm({ message: t('account_settings.rotate_confirm') })) {
              rotate.mutate()
            }
          }}
          type="button"
        >
          {payload.credential_status.api_token ? t('account_settings.rotate_token') : t('account_settings.generate_token')}
        </button>
        {payload.credential_status.api_token ? (
          <button
            className="rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:text-red-300 dark:disabled:text-red-500"
            disabled={revoke.isPending}
            onClick={async () => {
              if (await confirm({ message: t('account_settings.revoke_confirm'), destructive: true })) revoke.mutate()
            }}
            type="button"
          >
            {t('account_settings.revoke')}
          </button>
        ) : null}
      </div>
      {dialog}
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
    provider_availability_pause_thresholds: payload.user.provider_availability_pause_thresholds || { claude: 10, codex: 10 },
    scheduling_paused: payload.user.scheduling_paused,
    auto_approve_mode: payload.user.auto_approve_mode,
    locale: payload.user.locale
  }
}

function ProviderAvailabilitySettings({
  payload,
  values,
  setValues,
  onNotice
}: {
  payload: CredentialsPayload
  values: CredentialsInput
  setValues: (values: CredentialsInput) => void
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const recheck = useMutation({
    mutationFn: recheckProviderAvailability,
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      void queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      onNotice(updated.message || t("account_settings.provider_availability_rechecked"))
    }
  })
  const override = useMutation({
    mutationFn: overrideProviderAvailability,
    onSuccess: (updated) => {
      cacheCredentials(queryClient, updated)
      void queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      onNotice(updated.message || t("account_settings.provider_availability_overridden"))
    }
  })

  return (
    <div className="space-y-3 rounded border border-gray-200 p-3 dark:border-gray-700">
      <div>
        <h3 className="text-sm font-medium text-gray-700 dark:text-gray-300">{t("account_settings.provider_availability_heading")}</h3>
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("account_settings.provider_availability_desc")}</p>
      </div>
      {payload.options.agent_providers.map((provider) => {
        const availability = payload.provider_availability?.[provider]
        const threshold = values.provider_availability_pause_thresholds?.[provider] ?? 10
        return (
          <div className="grid gap-3 rounded border border-gray-100 p-3 dark:border-gray-800 sm:grid-cols-[1fr_auto] sm:items-center" key={provider}>
            <div className="min-w-0">
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                {t("account_settings.provider_availability_threshold", { provider: titleize(provider) })}
                <input
                  className={`${inputClass()} mt-2 max-w-32`}
                  max={100}
                  min={0}
                  onChange={(event) => setValues({
                    ...values,
                    provider_availability_pause_thresholds: {
                      ...values.provider_availability_pause_thresholds,
                      [provider]: Number(event.target.value)
                    }
                  })}
                  type="number"
                  value={threshold}
                />
              </label>
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                {availability?.usage?.remaining_percent != null
                  ? t("account_settings.provider_availability_remaining", { percent: Math.round(availability.usage.remaining_percent) })
                  : t("account_settings.provider_availability_no_usage")}
                {availability?.override_active ? ` ${t("account_settings.provider_availability_override_active")}` : ""}
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <button
                className="rounded bg-gray-100 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-200 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
                disabled={recheck.isPending}
                onClick={() => recheck.mutate(provider)}
                type="button"
              >
                {t("account_settings.provider_availability_recheck")}
              </button>
              <button
                className="rounded bg-amber-50 px-3 py-1.5 text-sm font-medium text-amber-800 hover:bg-amber-100 disabled:cursor-not-allowed disabled:opacity-60 dark:bg-amber-950/40 dark:text-amber-200"
                disabled={override.isPending}
                onClick={() => override.mutate(provider)}
                type="button"
              >
                {t("account_settings.provider_availability_override")}
              </button>
            </div>
          </div>
        )
      })}
      {recheck.isError ? <PanelMessage tone="error">{errorMessage(recheck.error, "Unable to recheck provider availability.")}</PanelMessage> : null}
      {override.isError ? <PanelMessage tone="error">{errorMessage(override.error, "Unable to override provider availability.")}</PanelMessage> : null}
    </div>
  )
}

function titleize(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}

