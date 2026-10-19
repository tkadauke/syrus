import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, EntityReference, StatePill } from "../toolCardUi"

type IdentityEntry = { key: string; value: string }
type DaemonPing = { ok: boolean; identity: IdentityEntry[] }

function identityValue(value: unknown): string {
  if (typeof value === "string") return value
  if (value == null) return "—"
  if (typeof value === "number" || typeof value === "boolean") return String(value)
  return JSON.stringify(value)
}

function parseDaemonPing(context: ToolCardContext): DaemonPing | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.ok !== "boolean") return null

  return {
    ok: parsed.ok,
    identity: isPlainObject(parsed.identity) ? Object.entries(parsed.identity).map(([key, value]) => ({ key, value: identityValue(value) })) : []
  }
}

function IdentityValue({ field, value }: { field: string; value: string }) {
  const workersHref = field === "worker_id" || field === "hostname" ? "/admin/queue/workers" : null
  return <EntityReference href={workersHref} kind="artifact" label={value} slug={value} wrap="break" />
}

function collapsedSummary(context: ToolCardContext) {
  const ping = parseDaemonPing(context)
  if (!ping) return null
  return ping.ok ? "daemon ping ok" : "daemon ping failed"
}

function renderExpanded(context: ToolCardContext) {
  const ping = parseDaemonPing(context)
  if (!ping) return null

  return (
    <CardShell>
      <StatePill state={ping.ok ? "ok" : "failed"} tone={ping.ok ? "success" : "failure"} />
      {ping.identity.length === 0 ? (
        <EmptyState>No daemon identity returned.</EmptyState>
      ) : (
        <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
          {ping.identity.map((entry) => (
            <div className="min-w-0" key={entry.key}>
              <dt className="text-2xs font-medium uppercase text-text-muted">{entry.key.replace(/_/g, " ")}</dt>
              <dd>
                <IdentityValue field={entry.key} value={entry.value} />
              </dd>
            </div>
          ))}
        </dl>
      )}
    </CardShell>
  )
}

const daemonPingToolCard: ToolCardRenderer = {
  toolName: "daemon_ping",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "healthy_daemon",
    label: "Healthy daemon",
    parsedResult: { ok: true, identity: { worker_id: "worker-1", hostname: "host-1", role: "worker", version: "abc123", pid: 42 } }
  },
  {
    id: "failed_ping",
    label: "Failed ping",
    parsedResult: { ok: false, identity: {} },
    resultError: true
  }
]

export default daemonPingToolCard
