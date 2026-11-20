import { useState, type FormEvent } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import {
  createProviderAccount,
  removeProviderAccount,
  testProviderAccount,
  updateProviderAccount,
  type CredentialsCorePayload,
  type CredentialsPayload,
  type ProviderAccount
} from "../api/credentials"
import { errorMessage } from "../lib/errorMessage"
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
  const credentialName = payload.options.provider_account_credential_attributes?.[provider]?.find((name) => name !== "codex_auth_mode") || ""
  const replaceAccount = (account: ProviderAccount) =>
    queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) =>
      current ? { ...current, provider_accounts: (current.provider_accounts || []).map((item) => (item.id === account.id ? account : item)) } : current
    )
  const create = useMutation({
    mutationFn: () => createProviderAccount({ provider_key: provider, label, credentials: { [credentialName]: secret } }),
    onSuccess: ({ provider_account, message }) => {
      queryClient.setQueryData<CredentialsCorePayload>(["credentials"], (current) =>
        current ? { ...current, provider_accounts: [...(current.provider_accounts || []), provider_account] } : current
      )
      setAdding(false)
      setLabel("")
      setSecret("")
      onNotice(message)
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
  const failure = create.error || update.error || test.error || remove.error
  const submit = (event: FormEvent) => {
    event.preventDefault()
    create.mutate()
  }
  return (
    <Surface data-testid="provider-accounts-panel">
      <div className="flex items-center justify-between gap-3">
        <div>
          <h2 className="font-semibold">{t("provider_accounts.title")}</h2>
          <p className="mt-1 text-xs text-text-secondary">{t("provider_accounts.description")}</p>
        </div>
        <button className="rounded border px-3 py-2 text-sm" onClick={() => setAdding(!adding)} type="button">
          {t("provider_accounts.add")}
        </button>
      </div>
      {failure ? (
        <p className="mt-3 text-sm text-danger-text" role="alert">
          {errorMessage(failure, t("provider_accounts.error"))}
        </p>
      ) : null}
      {adding ? (
        <form className="mt-4 grid gap-3 sm:grid-cols-3" onSubmit={submit}>
          <Form.Select aria-label={t("provider_accounts.provider")} onChange={(event) => setProvider(event.target.value)} value={provider}>
            {payload.options.agent_providers.map((key) => (
              <option key={key} value={key}>
                {payload.options.agent_provider_labels?.[key] || key}
              </option>
            ))}
          </Form.Select>
          <Form.Input
            aria-label={t("provider_accounts.label")}
            maxLength={100}
            onChange={(event) => setLabel(event.target.value)}
            placeholder={t("provider_accounts.label_optional")}
            value={label}
          />
          <Form.Input
            aria-label={t("provider_accounts.credential")}
            autoComplete="off"
            onChange={(event) => setSecret(event.target.value)}
            required
            type="password"
            value={secret}
          />
          <button className="rounded bg-brand px-3 py-2 text-sm text-white sm:col-start-3" disabled={create.isPending || !credentialName} type="submit">
            {t("provider_accounts.connect")}
          </button>
        </form>
      ) : null}
      <div className="mt-4 space-y-3">
        {(payload.provider_accounts || []).map((account) => (
          <ProviderAccountRow
            account={account}
            key={account.id}
            onRemove={() => remove.mutate(account.id)}
            onTest={() => test.mutate(account.id)}
            onUpdate={(values) => update.mutate({ id: account.id, values })}
          />
        ))}
      </div>
    </Surface>
  )
}

function ProviderAccountRow({
  account,
  onRemove,
  onTest,
  onUpdate
}: {
  account: ProviderAccount
  onRemove: () => void
  onTest: () => void
  onUpdate: (values: Parameters<typeof updateProviderAccount>[1]) => void
}) {
  const { t } = useT("settings")
  const [advanced, setAdvanced] = useState(false)
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
        <button
          className="rounded border px-2 py-1 text-xs"
          onClick={() => {
            const value = window.prompt(t("provider_accounts.rename_prompt"), account.label || "")
            if (value !== null) onUpdate({ label: value })
          }}
          type="button"
        >
          {t("provider_accounts.rename")}
        </button>
        <button className="rounded border px-2 py-1 text-xs disabled:opacity-50" disabled={!account.removable} onClick={onRemove} type="button">
          {t("provider_accounts.remove")}
        </button>
        <button aria-expanded={advanced} className="rounded border px-2 py-1 text-xs" onClick={() => setAdvanced(!advanced)} type="button">
          {t("provider_accounts.advanced")}
        </button>
      </div>
      {!account.removable ? <p className="mt-2 text-xs text-warning-text">{t("provider_accounts.remove_guard")}</p> : null}
      {advanced ? (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="text-xs">
            {t("provider_accounts.weight")}
            <Form.Input
              min="0.001"
              onBlur={(event) => onUpdate({ weight: Number(event.target.value) })}
              step="0.001"
              type="number"
              defaultValue={account.weight ?? 1}
            />
          </label>
          <label className="text-xs">
            {t("provider_accounts.threshold")}
            <Form.Input
              max="100"
              min="0"
              onBlur={(event) => onUpdate({ proactive_pause_threshold: Number(event.target.value) })}
              type="number"
              defaultValue={account.proactive_pause_threshold ?? account.effective_proactive_pause_threshold}
            />
          </label>
        </div>
      ) : null}
    </Surface>
  )
}
