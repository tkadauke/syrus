import i18n from "i18next"
import { CodeSurface, Notice } from "@app/components/ui"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardText } from "@app/toolCardSecurity"
import { Badge, CardShell, EmptyState, Row, SectionLabel, StatePill } from "@app/routes/chat/toolCardUi"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"

type TextBlock = { text: string; truncated: boolean; bytes: number | null; omittedBytes: number | null }
type SshExecCard = {
  error: string | null
  ok: boolean | null
  status: number | null
  target: string
  command: string | null
  credentialName: string | null
  credentialId: string | null
  credentialType: string | null
  port: string | null
  connectTimeout: string | null
  allowUnconstrainedHost: boolean
  allowRiskyCommand: boolean
  knownHostsEnforced: boolean | null
  fingerprint: string | null
  stdout: TextBlock
  stderr: TextBlock
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`chat:ssh_exec_card.${key}`, options)
}

function safe(value: unknown, identifier = false): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null
  const text = String(value).trim()
  return text ? redactToolCardText(text, !identifier) : null
}

function safeText(value: unknown): string {
  return typeof value === "string" ? redactToolCardText(value) : ""
}

function booleanValue(value: unknown): boolean | null {
  return typeof value === "boolean" ? value : null
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function jsonObject(text: string): Record<string, unknown> | null {
  try {
    const parsed: unknown = JSON.parse(text)
    return isPlainObject(parsed) ? parsed : null
  } catch {
    return null
  }
}

// MCP providers have emitted all three forms over time: a direct object,
// structured_content, and JSON serialized into the first text content block.
function resultPayload(value: unknown): Record<string, unknown> | null {
  if (!isPlainObject(value)) return null
  if (isPlainObject(value.structured_content)) return value.structured_content
  if (isPlainObject(value.result) && isPlainObject(value.result.structured_content)) return value.result.structured_content

  const content = Array.isArray(value.content) ? value.content : isPlainObject(value.result) && Array.isArray(value.result.content) ? value.result.content : []
  const text = content.find((block) => isPlainObject(block) && block.type === "text" && typeof block.text === "string")
  if (isPlainObject(text)) return jsonObject(text.text as string)
  return value
}

function textBlock(value: unknown): TextBlock {
  if (!isPlainObject(value)) return { text: "", truncated: false, bytes: null, omittedBytes: null }
  return {
    text: safeText(value.text),
    truncated: value.truncated === true,
    bytes: numberValue(value.bytes),
    omittedBytes: numberValue(value.omitted_bytes)
  }
}

export function parseSshExecCard(context: ToolCardContext): SshExecCard | null {
  const input = isPlainObject(context.input) ? context.input : {}
  const payload = resultPayload(context.parsedResult)
  const target = payload && isPlainObject(payload.target) ? payload.target : {}
  const credential = payload && isPlainObject(payload.credential) ? payload.credential : {}
  const errorText = context.resultError ? safe(context.resultBody) : null
  const host = safe(target.host) || safe(input.host)
  const user = safe(target.user) || safe(input.user)
  const port = safe(target.port) || safe(input.port)

  if (!payload && !errorText && !host && !user) return null

  return {
    error: errorText,
    ok: payload ? booleanValue(payload.ok) : null,
    status: payload ? numberValue(payload.status) : null,
    target: [user, host].filter(Boolean).join("@") + (port ? `:${port}` : ""),
    command: safe(input.command),
    credentialName: safe(credential.credential_name, true) || safe(input.credential, true),
    credentialId: safe(credential.credential_id, true),
    credentialType: safe(credential.credential_type, true),
    port,
    connectTimeout: safe(input.connect_timeout),
    allowUnconstrainedHost: input.allow_unconstrained_host === true,
    allowRiskyCommand: input.allow_risky_command === true,
    knownHostsEnforced: payload ? booleanValue(payload.known_hosts_enforced) : null,
    fingerprint: payload ? safe(payload.fingerprint, true) : null,
    stdout: textBlock(payload?.stdout),
    stderr: textBlock(payload?.stderr)
  }
}

function truncationLabel(block: TextBlock): string | null {
  if (!block.truncated) return null
  if (block.bytes != null && block.omittedBytes != null) return t("truncated_bytes", { bytes: block.bytes, omittedBytes: block.omittedBytes })
  if (block.bytes != null) return t("truncated_total", { bytes: block.bytes })
  return t("truncated")
}

function Output({ block, defaultOpen, label }: { block: TextBlock; defaultOpen: boolean; label: string }) {
  const truncation = truncationLabel(block)
  return (
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1" open={defaultOpen || undefined}>
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted hover:text-text-primary">
        <span className="mr-2">{label}</span>
        {truncation ? <Badge>{truncation}</Badge> : null}
      </summary>
      <div className="mt-2">
        {block.text ? (
          <TextPreview maxLines={20} modalLabel={t("full_output", { label })} text={block.text} truncate="tail" />
        ) : (
          <EmptyState>{t("empty_output", { label })}</EmptyState>
        )}
      </div>
    </details>
  )
}

export function SshExecCardBody({ card }: { card: SshExecCard }) {
  const failed = card.error != null || card.ok === false || (card.status != null && card.status !== 0)
  const state = card.error ? t("error") : card.ok === null ? t("unknown") : card.ok ? t("ok") : t("failed")

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={state} tone={failed ? "failure" : card.ok ? "success" : "neutral"} />
        {card.status != null ? <Badge>{t("exit_status", { status: card.status })}</Badge> : null}
        <span className="min-w-0 break-all font-mono text-xs font-semibold text-text-primary">{card.target || t("unknown_target")}</span>
        {card.allowUnconstrainedHost ? <StatePill state={t("unconstrained_host")} tone="warning" /> : null}
        {card.allowRiskyCommand ? <StatePill state={t("risky_command")} tone="warning" /> : null}
      </div>
      {card.error ? <Notice tone="danger">{card.error}</Notice> : null}
      <div className="grid gap-2 sm:grid-cols-3">
        <Row label={t("credential_name")} value={card.credentialName || t("not_available")} />
        <Row label={t("credential_id")} value={card.credentialId || t("not_available")} />
        <Row label={t("credential_type")} value={card.credentialType || t("not_available")} />
        <Row label={t("port")} value={card.port || t("default_port")} />
        <Row label={t("connect_timeout")} value={card.connectTimeout || t("default_value")} />
        <Row
          label={t("known_hosts")}
          value={card.knownHostsEnforced == null ? t("not_available") : card.knownHostsEnforced ? t("enforced") : t("not_enforced")}
        />
      </div>
      <div className="space-y-1">
        <SectionLabel>{t("command")}</SectionLabel>
        {card.command ? <CodeSurface code={card.command} copyLabel={t("copy_command")} mode="multiline" /> : <EmptyState>{t("empty_command")}</EmptyState>}
      </div>
      {card.fingerprint ? (
        <div className="space-y-1">
          <SectionLabel>{t("fingerprint")}</SectionLabel>
          <CodeSurface code={card.fingerprint} copyLabel={t("copy_fingerprint")} mode="multiline" />
        </div>
      ) : null}
      <Output block={card.stdout} defaultOpen label={t("stdout")} />
      <Output block={card.stderr} defaultOpen={failed} label={t("stderr")} />
    </CardShell>
  )
}

export function sshExecSummary(context: ToolCardContext): string | null {
  const card = parseSshExecCard(context)
  if (!card) return null
  const target = card.target || t("unknown_target")
  return card.error ? t("summary_error", { target }) : t("summary", { target, status: card.status ?? "?" })
}
