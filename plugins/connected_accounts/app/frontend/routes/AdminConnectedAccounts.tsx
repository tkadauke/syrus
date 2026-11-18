import { useState, type FormEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button, Input, Notice, Page, Section, SectionHeading, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { createProvider, deleteProvider, fetchProviders } from "../api/connectedAccounts"

const QUERY_KEY = ["admin", "connected_account_providers"]

export function AdminConnectedAccounts() {
  const { t } = useT("connected_accounts")
  const client = useQueryClient()
  const query = useQuery({ queryKey: QUERY_KEY, queryFn: fetchProviders })
  const [error, setError] = useState<string | null>(null)
  usePageTitle(t("admin.title"))
  const create = useMutation({ mutationFn: createProvider, onSuccess: () => client.invalidateQueries({ queryKey: QUERY_KEY }) })
  const remove = useMutation({ mutationFn: deleteProvider, onSuccess: () => client.invalidateQueries({ queryKey: QUERY_KEY }) })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError(null)
    const data = new FormData(event.currentTarget)
    const list = (name: string) =>
      String(data.get(name) || "")
        .split(/[\s,]+/)
        .filter(Boolean)
    create.mutate(
      {
        key: data.get("key"),
        display_name: data.get("display_name"),
        authorize_url: data.get("authorize_url"),
        token_url: data.get("token_url"),
        revoke_url: data.get("revoke_url"),
        identity_url: data.get("identity_url"),
        client_id: data.get("client_id"),
        client_secret: data.get("client_secret"),
        scopes: list("scopes"),
        api_origins: list("api_origins")
      },
      { onError: (value) => setError(value instanceof Error ? value.message : t("admin.save_error")) }
    )
  }

  return (
    <Page.Root aria-label={t("admin.title")} gutter="responsive" size="wide">
      <Page.Header className="pt-16 lg:pt-0">
        <Page.HeadingGroup>
          <Page.Title>{t("admin.title")}</Page.Title>
        </Page.HeadingGroup>
        <Page.Description>{t("admin.description")}</Page.Description>
      </Page.Header>
      {error ? <Notice tone="danger">{error}</Notice> : null}
      <Section.Root>
        <SectionHeading>{t("admin.configured")}</SectionHeading>
        {query.isPending ? <Notice>{t("admin.loading")}</Notice> : null}
        {query.isError ? <Notice tone="danger">{t("admin.load_error")}</Notice> : null}
        {query.data?.providers.map((provider) => (
          <div className="flex items-center justify-between border-b border-border py-3" key={provider.id}>
            <div>
              <Text as="p" variant="label">
                {provider.display_name}
              </Text>
              <Text as="p" muted>
                {provider.key} · {provider.authorize_url}
              </Text>
            </div>
            <Button variant="danger" onClick={() => remove.mutate(provider.id)}>
              {t("admin.delete")}
            </Button>
          </div>
        ))}
        {query.data?.providers.length === 0 ? <Text muted>{t("admin.empty")}</Text> : null}
      </Section.Root>
      <Section.Root>
        <SectionHeading>{t("admin.add")}</SectionHeading>
        <form className="grid max-w-3xl gap-3 md:grid-cols-2" onSubmit={submit}>
          {(
            ["key", "display_name", "authorize_url", "token_url", "revoke_url", "identity_url", "client_id", "client_secret", "scopes", "api_origins"] as const
          ).map((name) => (
            <label className="grid gap-1 text-sm" key={name}>
              {t(`admin.fields.${name}`)}
              <Input
                name={name}
                required={["key", "display_name", "authorize_url", "token_url", "client_id", "client_secret", "scopes", "api_origins"].includes(name)}
                type={name === "client_secret" ? "password" : "text"}
              />
            </label>
          ))}
          <div className="md:col-span-2">
            <Button type="submit" disabled={create.isPending}>
              {t("admin.create")}
            </Button>
          </div>
        </form>
      </Section.Root>
    </Page.Root>
  )
}

export default AdminConnectedAccounts
