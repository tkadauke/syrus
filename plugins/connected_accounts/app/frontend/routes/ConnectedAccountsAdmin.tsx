import { useEffect, useState, type FormEvent } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button, Checkbox, Input, Notice, Page, Select, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { loadPluginLocales } from "@app/i18n"
import { getJson, patchJson } from "@app/api/client"

type Config = Record<string, string | string[] | boolean>
type ProviderConfig = Config & {
  provider_key: string
  plugin_name: string
  display_name: string
  managed_settings: boolean
  client_secret_configured?: boolean
  settings_notice?: string | null
  settings_notice_i18n_key?: string | null
}
type ConfigPayload = { provider_config: ProviderConfig }
type ConfigsPayload = { providers: ProviderConfig[] }

export function ProviderSettingsNotice({ notice, i18nKey, pluginName }: { notice: string; i18nKey?: string | null; pluginName: string }) {
  const { i18n } = useT("connected_accounts")
  const [localeState, setLocaleState] = useState<"loading" | "loaded" | "failed">(i18nKey ? "loading" : "loaded")

  useEffect(() => {
    if (!i18nKey) return

    let current = true
    void loadPluginLocales(pluginName).then(
      () => { if (current) setLocaleState("loaded") },
      () => { if (current) setLocaleState("failed") }
    )
    return () => { current = false }
  }, [i18nKey, pluginName])

  if (localeState === "loading") return null
  return <Notice>{i18nKey && localeState === "loaded" ? i18n.t(i18nKey, { defaultValue: notice }) : notice}</Notice>
}

export default function ConnectedAccountsAdmin() {
  const { t } = useT("connected_accounts")
  const [draft, setDraft] = useState<Record<string, string | boolean>>({})
  const [configuredSecretProviders, setConfiguredSecretProviders] = useState<Set<string>>(() => new Set())
  const [provider, setProvider] = useState("")
  const query = useQuery({
    queryKey: ["connected_accounts", "provider_configs"],
    queryFn: async () => (await getJson<ConfigsPayload>("/api/v1/app/admin/connected_accounts/provider_configs")).providers
  })
  const selectedProvider = query.data?.some((item) => item.provider_key === provider) ? provider : (query.data?.[0]?.provider_key || provider)
  const current = query.data?.find((item) => item.provider_key === selectedProvider)
  const save = useMutation({
    mutationFn: async () => {
      const saved = current || ({} as ProviderConfig)
      const commaList = (field: string) => String(draft[field] || saved[field] || "").split(",").map((value) => value.trim()).filter(Boolean)
      const body = { provider_config: { ...draft, scope_catalog: commaList("scope_catalog"), read_only_scopes: commaList("read_only_scopes"), api_origins: commaList("api_origins") } }
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
  function submit(event: FormEvent) { event.preventDefault(); save.mutate() }
  const fields = [ "authorize_url", "token_url", "revoke_url", "identity_url", "validate_url", "client_id", "client_secret", "scope_catalog", "read_only_scopes", "api_origins" ]
  const visibleFields = fields.filter((field) => !current?.managed_settings || [ "client_id", "client_secret" ].includes(field))
  const clientSecretConfigured = Boolean(current?.client_secret_configured || configuredSecretProviders.has(selectedProvider))
  const changeProvider = (value: string) => {
    setProvider(value)
    setDraft({})
  }

  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header><Page.Title>{t("settings.title")}</Page.Title></Page.Header>
      <form className="max-w-3xl space-y-4" onSubmit={submit}>
        <Text>{t("settings.description")}</Text>
        <label className="block space-y-1">
          <span>{t("settings.provider")}</span>
          <Select value={selectedProvider} onChange={(event) => changeProvider(event.currentTarget.value)}>
            {query.data?.map((item) => <option key={item.provider_key} value={item.provider_key}>{item.display_name}</option>)}
          </Select>
        </label>
        {current?.settings_notice && (
          <ProviderSettingsNotice key={`${current.plugin_name}:${current.settings_notice_i18n_key || "fallback"}`}
            notice={current.settings_notice} i18nKey={current.settings_notice_i18n_key} pluginName={current.plugin_name} />
        )}
        {save.isSuccess && <Notice tone="success">{t("settings.saved")}</Notice>}
        {save.isError && <Notice tone="danger">{save.error.message || t("settings.save_failed")}</Notice>}
        {visibleFields.map((field) => (
          <label key={field} className="block space-y-1">
            <span>{t(`settings.${field}`)}</span>
            <Input aria-label={t(`settings.${field}`)} type={field === "client_secret" ? "password" : "text"} value={String(draft[field] ?? current?.[field] ?? "")}
              onChange={(event) => setDraft((value) => ({ ...value, [field]: event.target.value }))} />
            {field === "client_secret" && clientSecretConfigured && <Text variant="caption" tone="muted">{t("settings.client_secret_configured")}</Text>}
          </label>
        ))}
        <Checkbox checked={Boolean(draft.allow_as_owner ?? current?.allow_as_owner ?? false)} label={t("settings.allow_as_owner")}
          onChange={(event) => setDraft((value) => ({ ...value, allow_as_owner: event.target.checked }))} />
        <Button type="submit" disabled={save.isPending}>{t("settings.save")}</Button>
      </form>
    </Page.Root>
  )
}
