import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, Disclosure, Row, StatePill } from "@app/routes/chat/toolCardUi"
import { TextPreview } from "@app/routes/chat/toolCardMarkdown"
import { useT } from "@app/hooks/useT"

type SshExecResult = {
  ok: boolean
  status: number
  stdout: string
  stderr: string
  target: string | null
}

function outputText(value: unknown): string {
  if (!isPlainObject(value) || typeof value.text !== "string") return ""
  return value.text
}

function parseResult(context: ToolCardContext): SshExecResult | null {
  const result = context.parsedResult
  if (context.resultError || !isPlainObject(result) || typeof result.ok !== "boolean" || typeof result.status !== "number") return null

  const target = isPlainObject(result.target) ? result.target : null
  const host = target && typeof target.host === "string" ? target.host : null
  const user = target && typeof target.user === "string" ? target.user : null
  const port = target && typeof target.port === "number" ? target.port : null

  return {
    ok: result.ok,
    status: result.status,
    stdout: outputText(result.stdout),
    stderr: outputText(result.stderr),
    target: host ? `${user ? `${user}@` : ""}${host}${port ? `:${port}` : ""}` : null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return i18n.t(result.ok ? "common:ssh_exec_card.succeeded" : "common:ssh_exec_card.failed", { status: result.status })
}

function SshExecCard({ context, result }: { context: ToolCardContext; result: SshExecResult }) {
  const { t } = useT("common")
  const command = typeof context.input?.command === "string" ? context.input.command : null

  return (
    <CardShell>
      <StatePill state={result.ok ? "succeeded" : "failed"} />
      {result.target ? <Row label={t("ssh_exec_card.target")} value={result.target} /> : null}
      {command ? <Row label={t("ssh_exec_card.command")} value={command} /> : null}
      {result.stdout ? (
        <Disclosure label={t("ssh_exec_card.stdout")}>
          <TextPreview text={result.stdout} truncate="tail" />
        </Disclosure>
      ) : null}
      {result.stderr ? (
        <Disclosure label={t("ssh_exec_card.stderr")}>
          <TextPreview text={result.stderr} truncate="tail" />
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  return result ? <SshExecCard context={context} result={result} /> : null
}

const credentialStoreSshExecToolCard: ToolCardRenderer = {
  toolName: "credential_store_ssh_exec",
  collapsedSummary,
  renderExpanded
}

export default credentialStoreSshExecToolCard
