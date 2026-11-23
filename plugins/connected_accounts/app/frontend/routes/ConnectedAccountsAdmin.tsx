import { useState, type FormEvent } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button, Checkbox, Input, Notice, Page, Select, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { getJson, patchJson } from "@app/api/client"

type Config = Record<string, string | string[] | boolean>
type ProviderConfig = Config & {
  provider_key: string
  display_name: string
  managed_settings: boolean
  settings_notice?: string | null
  settings_notice_i18n_key?: string | null
}
type ConfigPayload = { provider_config: ProviderConfig }
type ConfigsPayload = { providers: ProviderConfig[] }

export default function ConnectedAccountsAdmin() {
  const { t } = useT("connected_accounts")
  const [draft, setDraft] = useState<Record<string, string | boolean>>({})
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
      await patchJson<ConfigPayload>(`/api/v1/app/admin/connected_accounts/provider_configs/${encodeURIComponent(selectedProvider)}`, body)
    }
  })
  function submit(event: FormEvent) { event.preventDefault(); save.mutate() }
  const fields = [ "authorize_url", "token_url", "revoke_url", "identity_url", "validate_url", "client_id", "client_secret", "scope_catalog", "read_only_scopes", "api_origins" ]
  const visibleFields = fields.filter((field) => !current?.managed_settings || [ "client_id", "client_secret" ].includes(field))
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
          <Notice>{current.settings_notice_i18n_key
            ? t(current.settings_notice_i18n_key, { defaultValue: current.settings_notice })
            : current.settings_notice}</Notice>
        )}
        {save.isSuccess && <Notice tone="success">{t("settings.saved")}</Notice>}
        {save.isError && <Notice tone="danger">{save.error.message || t("settings.save_failed")}</Notice>}
        {visibleFields.map((field) => (
          <label key={field} className="block space-y-1">
            <span>{t(`settings.${field}`)}</span>
            <Input type={field === "client_secret" ? "password" : "text"} value={String(draft[field] ?? current?.[field] ?? "")}
              onChange={(event) => setDraft((value) => ({ ...value, [field]: event.target.value }))} />
          </label>
        ))}
        <Checkbox checked={Boolean(draft.allow_as_owner ?? current?.allow_as_owner ?? false)} label={t("settings.allow_as_owner")}
          onChange={(event) => setDraft((value) => ({ ...value, allow_as_owner: event.target.checked }))} />
        <Button type="submit" disabled={save.isPending}>{t("settings.save")}</Button>
      </form>
    </Page.Root>
  )
}
