import { useState, type FormEvent } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button, Checkbox, Input, Notice, Page, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { getJson, patchJson } from "@app/api/client"

type Config = Record<string, string | string[] | boolean>
type ConfigPayload = { provider_config: Config }

export default function ConnectedAccountsAdmin() {
  const { t } = useT("connected_accounts")
  const [draft, setDraft] = useState<Record<string, string | boolean>>({})
  const query = useQuery({
    queryKey: ["connected_accounts", "provider_config"],
    queryFn: async () => {
      const payload = await getJson<ConfigPayload>("/api/v1/app/admin/connected_accounts/provider_config")
      return payload.provider_config
    }
  })
  const save = useMutation({
    mutationFn: async () => {
      const current = query.data || {}
      const body = {
        provider_config: {
          ...draft,
          scope_catalog: String(draft.scope_catalog || current.scope_catalog || "")
            .split(",")
            .map((v) => v.trim())
            .filter(Boolean),
          read_only_scopes: String(draft.read_only_scopes || current.read_only_scopes || "")
            .split(",")
            .map((v) => v.trim())
            .filter(Boolean),
          api_origins: String(draft.api_origins || current.api_origins || "")
            .split(",")
            .map((v) => v.trim())
            .filter(Boolean)
        }
      }
      await patchJson<ConfigPayload>("/api/v1/app/admin/connected_accounts/provider_config", body)
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
  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Page.Title>{t("settings.title")}</Page.Title>
      </Page.Header>
      <form className="max-w-3xl space-y-4" onSubmit={submit}>
        <Text>{t("settings.description")}</Text>
        {save.isSuccess && <Notice tone="success">{t("settings.saved")}</Notice>}
        {save.isError && <Notice tone="danger">{save.error.message || t("settings.save_failed")}</Notice>}
        {fields.map((field) => (
          <label key={field} className="block space-y-1">
            <span>{t(`settings.${field}`)}</span>
            <Input
              type={field === "client_secret" ? "password" : "text"}
              value={String(draft[field] ?? query.data?.[field] ?? "")}
              onChange={(event) => setDraft((current) => ({ ...current, [field]: event.target.value }))}
            />
          </label>
        ))}
        <Checkbox
          checked={Boolean(draft.allow_as_owner ?? query.data?.allow_as_owner ?? false)}
          label={t("settings.allow_as_owner")}
          onChange={(event) => setDraft((current) => ({ ...current, allow_as_owner: event.target.checked }))}
        />
        <Button type="submit" disabled={save.isPending}>
          {t("settings.save")}
        </Button>
      </form>
    </Page.Root>
  )
}
