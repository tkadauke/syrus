import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Button, Card, Checkbox, Notice, Page, Text } from "@app/components/ui"
import { deleteJson, getJson, patchJson } from "@app/api/client"
import { useT } from "@app/hooks/useT"

type Account = {
  id: number
  provider: string
  display_label: string
  status: string
  granted_scopes: string[]
  read_only: boolean
  acting_modes: string[]
  last_used_at: string | null
  reauthorize_url: string
}
type Provider = { key: string; display_name: string; scopes: string[]; supports_read_only: boolean }
type Payload = { accounts: Account[]; providers: Provider[] }

export default function ConnectedAccountsSettings() {
  const { t } = useT("connected_accounts")
  const client = useQueryClient()
  const query = useQuery({
    queryKey: ["connected_accounts", "accounts"],
    queryFn: (): Promise<Payload> => getJson("/api/v1/app/connected_accounts/accounts")
  })
  const refresh = () => client.invalidateQueries({ queryKey: ["connected_accounts", "accounts"] })
  const toggle = useMutation({
    mutationFn: ({ id, readOnly }: { id: number; readOnly: boolean }) =>
      patchJson(`/api/v1/app/connected_accounts/accounts/${id}`, { account: { read_only: readOnly } }),
    onSuccess: refresh
  })
  const disconnect = useMutation({
    mutationFn: (id: number) => deleteJson(`/api/v1/app/connected_accounts/accounts/${id}`),
    onSuccess: refresh
  })
  const error = query.error || toggle.error || disconnect.error

  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Page.Title>{t("accounts.title")}</Page.Title>
        <Text>{t("accounts.description")}</Text>
      </Page.Header>
      {error && <Notice tone="danger">{error.message}</Notice>}
      {query.isPending && <Notice>{t("accounts.loading")}</Notice>}
      <div className="space-y-4">
        {query.data?.accounts.map((account) => (
          <Card className="space-y-3 p-4" key={account.id}>
            <div>
              <h2 className="font-semibold text-text-primary">{account.display_label}</h2>
              <Text className="text-sm">{t("accounts.status", { status: t(`accounts.statuses.${account.status}`) })}</Text>
            </div>
            <Text className="text-sm">{t("accounts.scopes", { scopes: account.granted_scopes.join(", ") || t("accounts.none") })}</Text>
            <Text className="text-sm">
              {t("accounts.last_used", { value: account.last_used_at ? new Date(account.last_used_at).toLocaleString() : t("accounts.never") })}
            </Text>
            <Checkbox
              checked={account.read_only}
              disabled={toggle.isPending || account.status === "revoked"}
              label={t("accounts.read_only")}
              onChange={(event) => toggle.mutate({ id: account.id, readOnly: event.target.checked })}
            />
            <div className="flex flex-wrap gap-2">
              <a
                className="rounded-md border border-border px-3 py-2 text-sm font-medium text-text-primary hover:bg-surface-muted"
                href={account.reauthorize_url}
              >
                {t("accounts.reauthorize")}
              </a>
              {account.status !== "revoked" && (
                <Button disabled={disconnect.isPending} onClick={() => disconnect.mutate(account.id)} variant="danger" type="button">
                  {t("accounts.disconnect")}
                </Button>
              )}
            </div>
          </Card>
        ))}
        {query.data?.accounts.length === 0 && <Notice>{t("accounts.empty")}</Notice>}
      </div>
      <section className="mt-8 space-y-3">
        <h2 className="text-lg font-semibold text-text-primary">{t("accounts.connect")}</h2>
        <div className="flex flex-wrap gap-2">
          {query.data?.providers.map((provider) => (
            <a
              className="rounded-md bg-brand px-3 py-2 text-sm font-medium text-white hover:bg-brand/90"
              href={`/api/v1/app/connected_accounts/connect/${encodeURIComponent(provider.key)}?scopes=${encodeURIComponent(provider.scopes.join(","))}`}
              key={provider.key}
            >
              {t("accounts.connect_provider", { provider: provider.display_name })}
            </a>
          ))}
        </div>
      </section>
    </Page.Root>
  )
}
