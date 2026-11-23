import { useEffect, useState, type FormEvent } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button, Card, Checkbox, Input, Notice, Page, Select, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { loadPluginLocales } from "@app/i18n"
import { deleteJson, getJson, patchJson, postJson } from "@app/api/client"

type Config = Record<string, string | string[] | boolean>
type ProviderConfig = Config & {
  provider_key: string
  plugin_name: string
  display_name: string
  managed_settings: boolean
  client_secret_configured?: boolean
  settings_notice?: string | null
  settings_notice_i18n_key?: string | null
  authorization_kind?: string
}
type ConfigPayload = { provider_config: ProviderConfig }
type ConfigsPayload = { providers: ProviderConfig[] }
type InstanceAccount = { id: number; provider: string; display_label: string; status: string; last_used_at: string | null }
type InstancePayload = { accounts: InstanceAccount[]; providers: { key: string; display_name: string }[] }

export function ProviderSettingsNotice({ notice, i18nKey, pluginName }: { notice: string; i18nKey?: string | null; pluginName: string }) {
  const { i18n } = useT("connected_accounts")
  const [localeState, setLocaleState] = useState<"loading" | "loaded" | "failed">(i18nKey ? "loading" : "loaded")

  useEffect(() => {
    if (!i18nKey) return

    let current = true
    void loadPluginLocales(pluginName).then(
      () => {
        if (current) setLocaleState("loaded")
      },
      () => {
        if (current) setLocaleState("failed")
      }
    )
    return () => {
      current = false
    }
  }, [i18nKey, pluginName])

  if (localeState === "loading") return null
  return <Notice>{i18nKey && localeState === "loaded" ? i18n.t(i18nKey, { defaultValue: notice }) : notice}</Notice>
}

export default function ConnectedAccountsAdmin() {
  const { t } = useT("connected_accounts")
  const [draft, setDraft] = useState<Record<string, string | boolean>>({})
  const [configuredSecretProviders, setConfiguredSecretProviders] = useState<Set<string>>(() => new Set())
  const [provider, setProvider] = useState("")
  const [token, setToken] = useState("")
  const [label, setLabel] = useState("")
  const [tokenProvider, setTokenProvider] = useState("")
  const query = useQuery({
    queryKey: ["connected_accounts", "provider_configs"],
    queryFn: async () => {
      const payload = await getJson<ConfigsPayload>("/api/v1/app/admin/connected_accounts/provider_configs")
      return payload.providers
    }
  })
  const selectedProvider = query.data?.some((item) => item.provider_key === provider) ? provider : query.data?.[0]?.provider_key || provider
  const current = query.data?.find((item) => item.provider_key === selectedProvider)
  const instanceQuery = useQuery({
    queryKey: ["connected_accounts", "instance_accounts"],
    queryFn: (): Promise<InstancePayload> => getJson("/api/v1/app/admin/connected_accounts/instance_accounts"),
    enabled: query.data?.some((item) => item.authorization_kind === "token") === true
  })
  const selectedTokenProvider = instanceQuery.data?.providers?.some((item) => item.key === tokenProvider)
    ? tokenProvider
    : instanceQuery.data?.providers?.[0]?.key || ""
  const connectToken = useMutation({
    mutationFn: () =>
      postJson("/api/v1/app/admin/connected_accounts/instance_accounts", { account: { provider: selectedTokenProvider, token, display_label: label } }),
    onSuccess: () => {
      setToken("")
      setLabel("")
      void instanceQuery.refetch()
    }
  })
  const disconnectToken = useMutation({
    mutationFn: (id: number) => deleteJson(`/api/v1/app/admin/connected_accounts/instance_accounts/${id}`),
    onSuccess: () => void instanceQuery.refetch()
  })
  const save = useMutation({
    mutationFn: async () => {
      const saved = current || ({} as ProviderConfig)
      const commaList = (field: string) =>
        String(draft[field] || saved[field] || "")
          .split(",")
          .map((value) => value.trim())
          .filter(Boolean)
      const body = {
        provider_config: {
          ...draft,
          scope_catalog: commaList("scope_catalog"),
          read_only_scopes: commaList("read_only_scopes"),
          api_origins: commaList("api_origins")
        }
      }
      return patchJson<ConfigPayload>(`/api/v1/app/admin/connected_accounts/provider_configs/${encodeURIComponent(selectedProvider)}`, body)
    },
    onSuccess: ({ provider_config: saved }) => {
      if (saved.client_secret_configured) {
        setConfiguredSecretProviders((providers) => new Set(providers).add(saved.provider_key))
      }
      setDraft((value) => {
        const next = { ...value }
        delete next.client_secret
        return next
      })
    }
  })
  function submit(event: FormEvent) {
    event.preventDefault()
    save.mutate()
  }
  const fields = [
    "authorize_url",
    "token_url",
    "revoke_url",
    "identity_url",
    "validate_url",
    "client_id",
    "client_secret",
    "scope_catalog",
    "read_only_scopes",
    "api_origins"
  ]
  const visibleFields = fields.filter((field) => !current?.managed_settings || ["client_id", "client_secret"].includes(field))
  const clientSecretConfigured = Boolean(current?.client_secret_configured || configuredSecretProviders.has(selectedProvider))
  const changeProvider = (value: string) => {
    setProvider(value)
    setDraft({})
  }

  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Page.Title>{t("settings.title")}</Page.Title>
      </Page.Header>
      <form className="max-w-3xl space-y-4" onSubmit={submit}>
        <Text>{t("settings.description")}</Text>
        <label className="block space-y-1">
          <span>{t("settings.provider")}</span>
          <Select value={selectedProvider} onChange={(event) => changeProvider(event.currentTarget.value)}>
            {query.data?.map((item) => (
              <option key={item.provider_key} value={item.provider_key}>
                {item.display_name}
              </option>
            ))}
          </Select>
        </label>
        {current?.settings_notice && (
          <ProviderSettingsNotice
            key={`${current.plugin_name}:${current.settings_notice_i18n_key || "fallback"}`}
            notice={current.settings_notice}
            i18nKey={current.settings_notice_i18n_key}
            pluginName={current.plugin_name}
          />
        )}
        {save.isSuccess && <Notice tone="success">{t("settings.saved")}</Notice>}
        {save.isError && <Notice tone="danger">{save.error.message || t("settings.save_failed")}</Notice>}
        {visibleFields.map((field) => (
          <label key={field} className="block space-y-1">
            <span>{t(`settings.${field}`)}</span>
            <Input
              aria-label={t(`settings.${field}`)}
              type={field === "client_secret" ? "password" : "text"}
              value={String(draft[field] ?? current?.[field] ?? "")}
              onChange={(event) => setDraft((value) => ({ ...value, [field]: event.target.value }))}
            />
            {field === "client_secret" && clientSecretConfigured && (
              <Text variant="caption" tone="muted">
                {t("settings.client_secret_configured")}
              </Text>
            )}
          </label>
        ))}
        <Checkbox
          checked={Boolean(draft.allow_as_owner ?? current?.allow_as_owner ?? false)}
          label={t("settings.allow_as_owner")}
          onChange={(event) => setDraft((value) => ({ ...value, allow_as_owner: event.target.checked }))}
        />
        <Button type="submit" disabled={save.isPending}>
          {t("settings.save")}
        </Button>
      </form>
      {instanceQuery.data?.providers?.length ? (
        <section className="mt-10 max-w-3xl space-y-4">
          <h2 className="text-lg font-semibold text-text-primary">{t("instance.title")}</h2>
          <Text>{t("instance.description")}</Text>
          {connectToken.isError && <Notice tone="danger">{connectToken.error.message}</Notice>}
          <label className="block space-y-1">
            <span>{t("settings.provider")}</span>
            <Select value={selectedTokenProvider} onChange={(event) => setTokenProvider(event.currentTarget.value)}>
              {instanceQuery.data.providers.map((item) => (
                <option key={item.key} value={item.key}>
                  {item.display_name}
                </option>
              ))}
            </Select>
          </label>
          {instanceQuery.data.accounts?.map((account) => (
            <Card className="space-y-2 p-4" key={account.id}>
              <h3 className="font-semibold text-text-primary">{account.display_label}</h3>
              <Text>{t("instance.status", { status: account.status })}</Text>
              <div className="flex gap-2">
                <Button type="button" onClick={() => connectToken.mutate()} disabled={!token}>
                  {t("instance.rotate")}
                </Button>
                {account.status !== "revoked" && (
                  <Button type="button" variant="danger" onClick={() => disconnectToken.mutate(account.id)}>
                    {t("instance.disconnect")}
                  </Button>
                )}
              </div>
            </Card>
          ))}
          <label className="block space-y-1">
            <span>{t("instance.label")}</span>
            <Input value={label} onChange={(event) => setLabel(event.target.value)} />
          </label>
          <label className="block space-y-1">
            <span>{t("instance.token")}</span>
            <Input type="password" value={token} onChange={(event) => setToken(event.target.value)} />
          </label>
          <Button type="button" disabled={!token || connectToken.isPending} onClick={() => connectToken.mutate()}>
            {t("instance.connect")}
          </Button>
        </section>
      ) : null}
    </Page.Root>
  )
}
