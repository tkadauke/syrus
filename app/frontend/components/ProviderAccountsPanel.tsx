import { useState, type FormEvent } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import {
  createProviderAccount,
  exchangeClaudeOauth,
  exchangeCodexOauth,
  removeProviderAccount,
  startClaudeOauth,
  startCodexOauth,
  testProviderAccount,
  updateProviderAccount,
  type CredentialsCorePayload,
  type CredentialsPayload,
  type ProviderAccount
} from "../api/credentials"
import { errorMessage } from "../lib/errorMessage"
import { openInNewTab } from "../lib/desktopShell"
import { useT } from "../hooks/useT"
import { Form } from "./ui"
import { Surface } from "./ui/Surface"
import { TonePill } from "./StatusPill"

export function ProviderAccountsPanel({ payload, onNotice }: { payload: CredentialsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [adding, setAdding] = useState(false)
  const [provider, setProvider] = useState(payload.user.agent_provider)
  const [label, setLabel] = useState("")
  const [secret, setSecret] = useState("")
  const [authenticationKind, setAuthenticationKind] = useState(() =>
    payload.user.agent_provider === "codex"
      ? "api_key"
      : payload.options.provider_account_credential_attributes?.[payload.user.agent_provider]?.find((name) => name !== "codex_auth_mode") || "api_key"
  )
  const [editingAccount, setEditingAccount] = useState<ProviderAccount | null>(null)
  const [oauthStarted, setOauthStarted] = useState(false)
  const [oauthCode, setOauthCode] = useState("")
  const credentialName =
    provider === "codex"
      ? authenticationKind === "chatgpt_login"
        ? "codex_auth_json"
        : "codex_api_key"
      : payload.options.provider_account_credential_attributes?.[provider]?.find((name) => name !== "codex_auth_mode") || ""
  const replaceAccount = (account: ProviderAccount) =>
    queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) =>
      current ? { ...current, provider_accounts: (current.provider_accounts || []).map((item) => (item.id === account.id ? account : item)) } : current
    )
  const create = useMutation({
    mutationFn: () =>
      editingAccount
        ? updateProviderAccount(editingAccount.id, { authentication_kind: authenticationKind, credentials: { [credentialName]: secret } })
        : createProviderAccount({
            provider_key: provider,
            label,
            authentication_kind: authenticationKind,
            credentials: { [credentialName]: secret, ...(provider === "codex" ? { codex_auth_mode: authenticationKind } : {}) }
          }),
    onSuccess: ({ provider_account, message }) => {
      if (editingAccount) replaceAccount(provider_account)
      else
        queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) =>
          current ? { ...current, provider_accounts: [...(current.provider_accounts || []), provider_account] } : current
        )
      setAdding(false)
      setEditingAccount(null)
      setLabel("")
      setSecret("")
      onNotice(message)
    }
  })
  const oauthTarget = editingAccount ? { provider_account_id: editingAccount.id } : { provider_account: true, label }
  const oauthStart = useMutation({
    mutationFn: () => (provider === "claude" ? startClaudeOauth(oauthTarget) : startCodexOauth(oauthTarget)),
    onSuccess: ({ authorize_url }) => {
      openInNewTab(authorize_url)
      setOauthStarted(true)
    }
  })
  const oauthExchange = useMutation({
    mutationFn: () => (provider === "claude" ? exchangeClaudeOauth(oauthCode.trim(), oauthTarget) : exchangeCodexOauth(oauthCode.trim(), oauthTarget)),
    onSuccess: ({ provider_account, message }) => {
      if (provider_account) {
        queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) => {
          if (!current) return current
          const exists = (current.provider_accounts || []).some((account) => account.id === provider_account.id)
          return {
            ...current,
            provider_accounts: exists
              ? (current.provider_accounts || []).map((account) => (account.id === provider_account.id ? provider_account : account))
              : [...(current.provider_accounts || []), provider_account]
          }
        })
      }
      setAdding(false)
      setEditingAccount(null)
      setOauthStarted(false)
      setOauthCode("")
      setLabel("")
      onNotice(message || null)
    }
  })
  const update = useMutation({
    mutationFn: ({ id, values }: { id: string; values: Parameters<typeof updateProviderAccount>[1] }) => updateProviderAccount(id, values),
    onSuccess: ({ provider_account, message }) => {
      replaceAccount(provider_account)
      onNotice(message)
    }
  })
  const test = useMutation({
    mutationFn: testProviderAccount,
    onSuccess: ({ provider_account, message }) => {
      replaceAccount(provider_account)
      onNotice(message || null)
    }
  })
  const remove = useMutation({
    mutationFn: removeProviderAccount,
    onSuccess: ({ id, message }) => {
      queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) =>
        current ? { ...current, provider_accounts: (current.provider_accounts || []).filter((account) => account.id !== id) } : current
      )
      onNotice(message)
    }
  })
  const failure = create.error || update.error || test.error || remove.error || oauthStart.error || oauthExchange.error
  const submit = (event: FormEvent) => {
    event.preventDefault()
    create.mutate()
  }
  const closeEditor = () => {
    setAdding(false)
    setEditingAccount(null)
    setLabel("")
    setSecret("")
    setOauthStarted(false)
    setOauthCode("")
  }
  const manualActions = (
    <div className="mt-3 flex flex-wrap justify-end gap-2">
      <button className="rounded border px-3 py-2 text-sm" onClick={closeEditor} type="button">
        {t("provider_accounts.cancel")}
      </button>
      <button
        className="rounded bg-brand px-3 py-2 text-sm text-white disabled:opacity-50"
        disabled={create.isPending || !credentialName || !secret.trim()}
        type="submit"
      >
        {editingAccount ? t("provider_accounts.replace") : t("provider_accounts.connect")}
      </button>
    </div>
  )
  return (
    <Surface data-testid="provider-accounts-panel">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h2 className="font-semibold">{t("provider_accounts.title")}</h2>
          <p className="mt-1 text-xs text-text-secondary">{t("provider_accounts.description")}</p>
        </div>
        <button
          className="rounded border px-3 py-2 text-sm"
          onClick={() => {
            setAdding(!adding)
            setEditingAccount(null)
          }}
          type="button"
        >
          {t((payload.provider_accounts || []).length === 0 ? "provider_accounts.setup" : "provider_accounts.add")}
        </button>
      </div>
      {failure ? (
        <p className="mt-3 text-sm text-danger-text" role="alert">
          {errorMessage(failure, t("provider_accounts.error"))}
        </p>
      ) : null}
      {adding ? (
        <form className="mt-4 grid gap-3 sm:grid-cols-3" onSubmit={submit}>
          <Form.Field>
            <Form.Label>{t("provider_accounts.provider")}</Form.Label>
            <Form.Select
              disabled={Boolean(editingAccount)}
              onChange={(event) => {
                const next = event.target.value
                setProvider(next)
                setAuthenticationKind(
                  next === "codex"
                    ? "api_key"
                    : payload.options.provider_account_credential_attributes?.[next]?.find((name) => name !== "codex_auth_mode") || "api_key"
                )
              }}
              value={provider}
            >
              {payload.options.agent_providers.map((key) => (
                <option key={key} value={key}>
                  {payload.options.agent_provider_labels?.[key] || key}
                </option>
              ))}
            </Form.Select>
          </Form.Field>
          {provider === "codex" ? (
            <Form.Field>
              <Form.Label>{t("provider_accounts.auth_method")}</Form.Label>
              <Form.Select onChange={(event) => setAuthenticationKind(event.target.value)} value={authenticationKind}>
                <option value="api_key">{t("provider_accounts.api_key")}</option>
                <option value="chatgpt_login">{t("provider_accounts.chatgpt_login")}</option>
              </Form.Select>
            </Form.Field>
          ) : null}
          {!editingAccount ? (
            <Form.Field>
              <Form.Label>{t("provider_accounts.label")}</Form.Label>
              <Form.Input
                maxLength={100}
                onChange={(event) => setLabel(event.target.value)}
                placeholder={t("provider_accounts.label_optional")}
                value={label}
              />
            </Form.Field>
          ) : null}
          {provider === "claude" || (provider === "codex" && authenticationKind === "chatgpt_login") ? (
            <div className="space-y-2 sm:col-span-3">
              <button
                className="rounded bg-brand px-3 py-2 text-sm text-white"
                disabled={oauthStart.isPending}
                onClick={() => oauthStart.mutate()}
                type="button"
              >
                {t("provider_accounts.authorize", { provider: payload.options.agent_provider_labels?.[provider] || provider })}
              </button>
              {oauthStarted ? (
                <Form.Field>
                  <Form.Label>{t("provider_accounts.oauth_code")}</Form.Label>
                  <Form.Input onChange={(event) => setOauthCode(event.target.value)} value={oauthCode} />
                  <button
                    className="mt-2 rounded border px-3 py-2 text-sm"
                    disabled={!oauthCode.trim() || oauthExchange.isPending}
                    onClick={() => oauthExchange.mutate()}
                    type="button"
                  >
                    {t("provider_accounts.connect")}
                  </button>
                </Form.Field>
              ) : null}
              <details>
                <summary className="cursor-pointer text-sm">{t("provider_accounts.manual_alternative")}</summary>
                <div className="mt-3">
                  <AccountSecretField secret={secret} setSecret={setSecret} t={t} />
                  {manualActions}
                </div>
              </details>
            </div>
          ) : (
            <div className="sm:col-span-3">
              <AccountSecretField secret={secret} setSecret={setSecret} t={t} />
              {manualActions}
            </div>
          )}
        </form>
      ) : null}
      <div className="mt-4 space-y-3">
        {(payload.provider_accounts || []).map((account) => (
          <ProviderAccountRow
            account={account}
            key={account.id}
            onRemove={() => remove.mutate(account.id)}
            onReplace={() => {
              setProvider(account.provider_key)
              setAuthenticationKind(account.authentication_kind)
              setEditingAccount(account)
              setAdding(true)
              setSecret("")
              setOauthStarted(false)
            }}
            onTest={() => test.mutate(account.id)}
            onUpdate={(values) => update.mutate({ id: account.id, values })}
          />
        ))}
      </div>
    </Surface>
  )
}

function AccountSecretField({
  secret,
  setSecret,
  t
}: {
  secret: string
  setSecret: (value: string) => void
  t: (key: string, options?: Record<string, unknown>) => string
}) {
  return (
    <Form.Field>
      <Form.Label>{t("provider_accounts.credential")}</Form.Label>
      <Form.Input autoComplete="off" onChange={(event) => setSecret(event.target.value)} required type="password" value={secret} />
    </Form.Field>
  )
}

function ProviderAccountRow({
  account,
  onRemove,
  onReplace,
  onTest,
  onUpdate
}: {
  account: ProviderAccount
  onRemove: () => void
  onReplace: () => void
  onTest: () => void
  onUpdate: (values: Parameters<typeof updateProviderAccount>[1]) => void
}) {
  const { t } = useT("settings")
  const [advanced, setAdvanced] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [draftLabel, setDraftLabel] = useState(account.label || "")
  const usage = account.availability?.usage
  return (
    <Surface padding="sm" variant="subtle">
      <div className="flex flex-wrap items-center gap-2">
        <strong>{account.display_label}</strong>
        <TonePill tone={account.enabled ? "green" : "gray"}>{account.enabled ? t("provider_accounts.enabled") : t("provider_accounts.disabled")}</TonePill>
        <span className="text-xs text-text-secondary">{account.availability?.state || t("provider_accounts.unknown")}</span>
      </div>
      {usage ? (
        <p className="mt-2 text-xs text-text-secondary">
          {t("provider_accounts.remaining", { value: usage.remaining_percent ?? t("provider_accounts.unknown") })}
          {usage.windows?.five_hour?.reset_at
            ? ` · ${t("provider_accounts.resets", { value: new Date(usage.windows.five_hour.reset_at).toLocaleString() })}`
            : ""}
        </p>
      ) : null}
      <div className="mt-3 flex flex-wrap gap-2">
        <button className="rounded border px-2 py-1 text-xs" onClick={onTest} type="button">
          {t("provider_accounts.test")}
        </button>
        <button className="rounded border px-2 py-1 text-xs" onClick={() => onUpdate({ enabled: !account.enabled })} type="button">
          {account.enabled ? t("provider_accounts.disable") : t("provider_accounts.enable")}
        </button>
        <button className="rounded border px-2 py-1 text-xs" onClick={onReplace} type="button">
          {t("provider_accounts.replace")}
        </button>
        <button className="rounded border px-2 py-1 text-xs" onClick={() => setRenaming(true)} type="button">
          {t("provider_accounts.rename")}
        </button>
        <button className="rounded border px-2 py-1 text-xs disabled:opacity-50" disabled={!account.removable} onClick={onRemove} type="button">
          {t("provider_accounts.remove")}
        </button>
        <button aria-expanded={advanced} className="rounded border px-2 py-1 text-xs" onClick={() => setAdvanced(!advanced)} type="button">
          {t("provider_accounts.advanced")}
        </button>
      </div>
      {renaming ? (
        <div className="mt-3 flex items-end gap-2">
          <Form.Field className="grow">
            <Form.Label>{t("provider_accounts.label")}</Form.Label>
            <Form.Input autoFocus maxLength={100} onChange={(event) => setDraftLabel(event.target.value)} value={draftLabel} />
          </Form.Field>
          <button
            className="rounded border px-3 py-2 text-sm"
            onClick={() => {
              onUpdate({ label: draftLabel })
              setRenaming(false)
            }}
            type="button"
          >
            {t("provider_accounts.save")}
          </button>
          <button className="rounded border px-3 py-2 text-sm" onClick={() => setRenaming(false)} type="button">
            {t("provider_accounts.cancel")}
          </button>
        </div>
      ) : null}
      {!account.removable ? <p className="mt-2 text-xs text-warning-text">{t("provider_accounts.remove_guard")}</p> : null}
      {advanced ? (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <Form.Field>
            <Form.Label>{t("provider_accounts.weight")}</Form.Label>
            <Form.Input
              min="0.001"
              onBlur={(event) => onUpdate({ weight: Number(event.target.value) })}
              step="0.001"
              type="number"
              defaultValue={account.weight ?? 1}
            />
          </Form.Field>
          <Form.Field>
            <Form.Label>{t("provider_accounts.threshold")}</Form.Label>
            <Form.Input
              max="100"
              min="0"
              onBlur={(event) => onUpdate({ proactive_pause_threshold: Number(event.target.value) })}
              type="number"
              defaultValue={account.proactive_pause_threshold ?? account.effective_proactive_pause_threshold}
            />
          </Form.Field>
        </div>
      ) : null}
    </Surface>
  )
}
