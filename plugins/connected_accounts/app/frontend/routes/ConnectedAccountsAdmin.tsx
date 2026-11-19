import { useState, type FormEvent } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import { Button, Input, Notice, Page, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"

type Config = Record<string, string | string[] | boolean>

export default function ConnectedAccountsAdmin() {
  const { t } = useT("connected_accounts")
  const [draft, setDraft] = useState<Record<string, string>>({})
  const query = useQuery({ queryKey: ["connected_accounts", "provider_config"], queryFn: async () => {
    const response = await fetch("/api/v1/app/admin/connected_accounts/provider_config")
    if (!response.ok) throw new Error("Unable to load provider configuration")
    return (await response.json()).provider_config as Config
  } })
  const save = useMutation({ mutationFn: async () => {
    const current = query.data || {}
    const body = { provider_config: { ...draft,
      scope_catalog: (draft.scope_catalog || String(current.scope_catalog || "")).split(",").map(v => v.trim()).filter(Boolean),
      api_origins: (draft.api_origins || String(current.api_origins || "")).split(",").map(v => v.trim()).filter(Boolean) } }
    const response = await fetch("/api/v1/app/admin/connected_accounts/provider_config", { method: "PUT", headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content || "" }, body: JSON.stringify(body) })
    if (!response.ok) throw new Error((await response.json()).message || "Unable to save provider configuration")
  } })
  function submit(event: FormEvent) { event.preventDefault(); save.mutate() }
  const fields = ["authorize_url", "token_url", "revoke_url", "identity_url", "validate_url", "client_id", "client_secret", "scope_catalog", "api_origins"]
  return <Page.Root gutter="responsive" size="narrow"><Page.Header><Page.Title>{t("settings.title")}</Page.Title></Page.Header><form className="max-w-3xl space-y-4" onSubmit={submit}>
    <Text>{t("settings.description")}</Text>
    {save.isSuccess && <Notice tone="success">{t("settings.saved")}</Notice>}
    {fields.map(field => <label key={field} className="block space-y-1"><span>{t(`settings.${field}`)}</span><Input type={field === "client_secret" ? "password" : "text"} value={draft[field] ?? String(query.data?.[field] || "")} onChange={event => setDraft({ ...draft, [field]: event.target.value })} /></label>)}
    <Button type="submit" disabled={save.isPending}>{t("settings.save")}</Button>
  </form></Page.Root>
}
