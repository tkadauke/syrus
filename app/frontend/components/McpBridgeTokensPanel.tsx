import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type FormEvent } from "react"
import { fetchMcpBridgeTokens, issueMcpBridgeToken, revokeMcpBridgeToken, type IssuedMcpBridgeToken } from "../api/mcpBridgeTokens"
import { useConfirm } from "../hooks/useConfirm"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Button } from "./Button"
import { SectionHeading } from "./Heading"
import { Input } from "./Input"
import { PanelMessage } from "./PanelMessage"

const QUERY_KEY = ["mcp-bridge-tokens"]

// Tokens an external MCP client (Claude Code, say) uses to call this user's
// chat tools through /mcp/bridge. The plaintext is shown once, with the
// command that registers it.
export function McpBridgeTokensPanel() {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [name, setName] = useState("")
  const [issued, setIssued] = useState<IssuedMcpBridgeToken | null>(null)
  const tokens = useQuery({ queryKey: QUERY_KEY, queryFn: fetchMcpBridgeTokens })
  const issue = useMutation({
    mutationFn: issueMcpBridgeToken,
    onSuccess: (result) => {
      setIssued(result)
      setName("")
      void queryClient.invalidateQueries({ queryKey: QUERY_KEY })
    }
  })
  const revoke = useMutation({
    mutationFn: revokeMcpBridgeToken,
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: QUERY_KEY })
  })

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (name.trim()) issue.mutate(name.trim())
  }

  const active = (tokens.data?.tokens ?? []).filter((token) => !token.revoked_at)

  return (
    <section className="rounded border border-border bg-surface p-5" data-testid="mcp-bridge-tokens">
      <SectionHeading>{t("mcp_bridge.heading")}</SectionHeading>
      <p className="mt-1 text-xs text-text-muted">{t("mcp_bridge.description")}</p>

      {issued ? (
        <div className="mt-3 rounded border border-success-border bg-success-surface p-3">
          <div className="text-xs font-medium uppercase text-success-text">{t("mcp_bridge.new_token")}</div>
          <code className="mt-1 block break-all font-mono text-sm">{issued.plaintext}</code>
          <div className="mt-2 text-xs text-text-secondary">{t("mcp_bridge.register_hint")}</div>
          <code className="mt-1 block break-all font-mono text-xs">
            {`claude mcp add --transport http syrus ${issued.endpoint} --header "Authorization: Bearer ${issued.plaintext}"`}
          </code>
        </div>
      ) : null}

      <form className="mt-3 flex gap-2" onSubmit={submit}>
        <Input
          aria-label={t("mcp_bridge.name_label")}
          onChange={(event) => setName(event.target.value)}
          placeholder={t("mcp_bridge.name_placeholder")}
          value={name}
        />
        <Button disabled={issue.isPending || !name.trim()} size="sm" type="submit" variant="secondary">
          {t("mcp_bridge.issue")}
        </Button>
      </form>

      {issue.isError ? <PanelMessage tone="error">{errorMessage(issue.error, t("mcp_bridge.issue_error"))}</PanelMessage> : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, t("mcp_bridge.revoke_error"))}</PanelMessage> : null}
      {tokens.isError ? <PanelMessage tone="error">{errorMessage(tokens.error, t("mcp_bridge.load_error"))}</PanelMessage> : null}

      {active.length > 0 ? (
        <ul className="mt-3 divide-y divide-border">
          {active.map((token) => (
            <li className="flex items-center justify-between gap-2 py-2 text-sm" key={token.id}>
              <span className="min-w-0 truncate">
                <span className="font-medium">{token.name}</span>{" "}
                <code className="font-mono text-xs text-text-muted">{token.token_prefix}…</code>{" "}
                <span className="text-xs text-text-muted">
                  {token.last_used_at ? t("mcp_bridge.last_used", { time: new Date(token.last_used_at).toLocaleString() }) : t("mcp_bridge.never_used")}
                </span>
              </span>
              <Button
                disabled={revoke.isPending}
                onClick={async () => {
                  if (await confirm({ message: t("mcp_bridge.revoke_confirm", { name: token.name }), destructive: true })) revoke.mutate(token.id)
                }}
                size="sm"
                type="button"
                variant="danger"
              >
                {t("mcp_bridge.revoke")}
              </Button>
            </li>
          ))}
        </ul>
      ) : tokens.isSuccess ? (
        <p className="mt-3 text-xs text-text-muted">{t("mcp_bridge.none")}</p>
      ) : null}
      {dialog}
    </section>
  )
}
