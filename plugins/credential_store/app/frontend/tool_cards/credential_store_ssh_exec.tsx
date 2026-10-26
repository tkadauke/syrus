import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { redactToolCardText, redactToolCardValue, toolCardPayloadSizeLabel } from "@app/toolCardSecurity"
import { Badge, CardShell, Disclosure, EmptyState, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { useT } from "@app/hooks/useT"

type OutputBlock = { text: string; truncated: boolean; bytes: number | null; omittedBytes: number | null }
type CredentialMetadata = { id: string | null; name: string | null; type: string | null }
type SshExecResult = {
  ok: boolean
  status: number
  stdout: OutputBlock
  stderr: OutputBlock
  target: string | null
  credential: CredentialMetadata
  knownHostsEnforced: boolean | null
  fingerprint: string | null
}

function safeText(value: unknown): string | null {
  if (typeof value !== "string" && typeof value !== "number") return null
  const text = redactToolCardText(String(value)).trim()
  return text || null
}

function outputBlock(value: unknown): OutputBlock {
  if (!isPlainObject(value)) return { text: "", truncated: false, bytes: null, omittedBytes: null }
  return {
    text: typeof value.text === "string" ? redactToolCardText(value.text) : "",
    truncated: value.truncated === true,
    bytes: typeof value.bytes === "number" && Number.isFinite(value.bytes) ? value.bytes : null,
    omittedBytes: typeof value.omitted_bytes === "number" && Number.isFinite(value.omitted_bytes) ? value.omitted_bytes : null
  }
}

function credentialMetadata(value: unknown): CredentialMetadata {
  if (!isPlainObject(value)) return { id: null, name: null, type: null }
  return {
    id: safeText(value.credential_id ?? value.id),
    name: safeText(value.credential_name ?? value.name),
    type: safeText(value.credential_type ?? value.type)
  }
}

function targetLabel(value: unknown): string | null {
  if (!isPlainObject(value)) return null
  const host = safeText(value.host)
  const user = safeText(value.user)
  const port = typeof value.port === "number" && Number.isFinite(value.port) ? value.port : null
  return host ? `${user ? `${user}@` : ""}${host}${port ? `:${port}` : ""}` : null
}

function parseResult(context: ToolCardContext): SshExecResult | null {
  const result = redactToolCardValue(context.parsedResult)
  if (!isPlainObject(result) || typeof result.ok !== "boolean" || typeof result.status !== "number") return null

  return {
    ok: result.ok,
    status: result.status,
    stdout: outputBlock(result.stdout),
    stderr: outputBlock(result.stderr),
    target: targetLabel(result.target),
    credential: credentialMetadata(result.credential),
    knownHostsEnforced: typeof result.known_hosts_enforced === "boolean" ? result.known_hosts_enforced : null,
    fingerprint: safeText(result.fingerprint)
  }
}

function requestedTarget(input: Record<string, unknown> | undefined): string | null {
  const host = safeText(input?.host)
  const user = safeText(input?.user)
  const port = typeof input?.port === "number" && Number.isFinite(input.port) ? input.port : null
  return host ? `${user ? `${user}@` : ""}${host}${port ? `:${port}` : ""}` : null
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (result) {
    const target = result.target ?? requestedTarget(context.input)
    return i18n.t("credential_store:ssh_exec_card.summary", {
      target: target ?? i18n.t("credential_store:ssh_exec_card.unknown_target"),
      status: result.status
    })
  }
  return context.resultError ? i18n.t("credential_store:ssh_exec_card.error_summary") : null
}

function byteCountLabel(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function Output({ label, output, open }: { label: string; output: OutputBlock; open: boolean }) {
  const { t } = useT("credential_store")
  const size = output.bytes == null ? toolCardPayloadSizeLabel(output.text) : byteCountLabel(output.bytes)
  return (
    <Disclosure defaultOpen={open} label={label}>
      {output.truncated ? (
        <div className="mb-1">
          <Badge>
            {output.omittedBytes == null
              ? t("ssh_exec_card.truncated_size", { size })
              : t("ssh_exec_card.truncated_omitted", { size, omitted: byteCountLabel(output.omittedBytes) })}
          </Badge>
        </div>
      ) : null}
      <TextPreview emptyLabel={t("ssh_exec_card.empty_output")} modalLabel={label} text={output.text} truncate="tail" />
    </Disclosure>
  )
}

function Credential({ metadata, fallback }: { metadata: CredentialMetadata; fallback: unknown }) {
  const { t } = useT("credential_store")
  const id = metadata.id ?? safeText(fallback)
  if (!metadata.name && !id && !metadata.type) return null
  return (
    <div className="grid min-w-0 grid-cols-1 gap-2 sm:grid-cols-3">
      {metadata.name ? <Row label={t("ssh_exec_card.credential_name")} value={metadata.name} /> : null}
      {id ? <Row label={t("ssh_exec_card.credential_id")} value={id} /> : null}
      {metadata.type ? <Row label={t("ssh_exec_card.credential_type")} value={metadata.type} /> : null}
    </div>
  )
}

function SshExecCard({ context, result }: { context: ToolCardContext; result: SshExecResult }) {
  const { t } = useT("credential_store")
  const input = redactToolCardValue(context.input ?? {}) as Record<string, unknown>
  const command = safeText(input.command)
  const target = result.target ?? requestedTarget(input)

  return (
    <CardShell tone={result.ok ? "success" : "danger"}>
      <div className="flex flex-wrap items-center gap-1.5">
        <StatePill state={result.ok ? "succeeded" : "failed"} />
        <Badge>{t("ssh_exec_card.exit_status", { status: result.status })}</Badge>
        {input.allow_unconstrained_host === true ? <Badge>{t("ssh_exec_card.unconstrained_host")}</Badge> : null}
        {input.allow_risky_command === true ? <Badge>{t("ssh_exec_card.risky_command")}</Badge> : null}
      </div>
      {target ? <Row copyable label={t("ssh_exec_card.target")} value={target} wrap /> : null}
      <Credential fallback={input.credential} metadata={result.credential} />
      {command ? <Row copyable label={t("ssh_exec_card.command")} value={command} wrap /> : null}
      {input.connect_timeout != null ? (
        <Row label={t("ssh_exec_card.connect_timeout")} value={t("ssh_exec_card.seconds", { count: input.connect_timeout })} />
      ) : null}
      {result.knownHostsEnforced != null ? (
        <Row label={t("ssh_exec_card.known_hosts_enforced")} value={t(result.knownHostsEnforced ? "ssh_exec_card.yes" : "ssh_exec_card.no")} />
      ) : null}
      {result.fingerprint ? <Row copyable label={t("ssh_exec_card.fingerprint")} value={result.fingerprint} wrap /> : null}
      <Output label={t("ssh_exec_card.stdout")} open={Boolean(result.stdout.text)} output={result.stdout} />
      <Output label={t("ssh_exec_card.stderr")} open={!result.ok && Boolean(result.stderr.text)} output={result.stderr} />
    </CardShell>
  )
}

function ErrorCard({ context }: { context: ToolCardContext }) {
  const { t } = useT("credential_store")
  const error = redactToolCardText(context.resultBody).trim()
  return (
    <CardShell tone="danger">
      <StatePill state="error" />
      {error ? <TextPreview text={error} /> : <EmptyState>{t("ssh_exec_card.empty_error")}</EmptyState>}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (result) return <SshExecCard context={context} result={result} />
  if (context.resultError) return <ErrorCard context={context} />
  return null
}

const credentialStoreSshExecToolCard: ToolCardRenderer = {
  toolName: "credential_store_ssh_exec",
  argumentSummary: () => "",
  collapsedSummary,
  renderExpanded
}

export default credentialStoreSshExecToolCard
