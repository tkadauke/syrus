import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, Row, SectionLabel } from "../toolCardUi"
import { HealthPill, parseHealthLevel, parseWorkerHealthCounts, Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_version (the tool-card work). Renders the
// request-handling instance's own identity, the live instance roster
// (rolling deploy visibility -- old and new SHAs both show up mid-rollout),
// and an aggregate worker-health rollup.
type InstanceRow = {
  key: string
  hostname: string
  role: string | null
  version: string | null
  startedAt: string | null
  lastHeartbeatAt: string | null
  diskLevel: string | null
  diskUsedPercent: number | null
}

function parseInstanceRow(value: unknown, index: number): InstanceRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  const diskUsage = isPlainObject(value.data_root_usage) ? value.data_root_usage : null

  return {
    key: `${hostname}-${index}`,
    hostname,
    role: displayValue(value.role),
    version: displayValue(value.version),
    startedAt: displayValue(value.started_at),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    diskLevel: diskUsage ? displayValue(diskUsage.level) : null,
    diskUsedPercent: diskUsage && typeof diskUsage.used_percent === "number" ? diskUsage.used_percent : null
  }
}

type VersionCard = {
  requestHandlerHostname: string | null
  requestHandlerRole: string | null
  requestHandlerVersion: string | null
  instances: InstanceRow[]
  workerHealth: ReturnType<typeof parseWorkerHealthCounts>
}

function parseVersionCard(context: ToolCardContext): VersionCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.request_handler) || !Array.isArray(parsed.instances)) return null

  return {
    requestHandlerHostname: displayValue(parsed.request_handler.hostname),
    requestHandlerRole: displayValue(parsed.request_handler.role),
    requestHandlerVersion: displayValue(parsed.request_handler.version),
    instances: parsed.instances.flatMap((instance, index) => { const row = parseInstanceRow(instance, index); return row ? [row] : [] }),
    workerHealth: parseWorkerHealthCounts(parsed.worker_health)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseVersionCard(context)
  if (!card) return null

  const versions = new Set(card.instances.map((instance) => instance.version).filter(Boolean))
  const mixed = versions.size > 1 ? " (mixed versions -- deploy in progress?)" : ""
  return `${card.instances.length} live instance${card.instances.length === 1 ? "" : "s"}${mixed}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseVersionCard(context)
  if (!card) return null

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label="Handling host" value={card.requestHandlerHostname ?? "—"} />
        <Row label="Role" value={card.requestHandlerRole ?? "—"} />
        <Row label="Version" value={card.requestHandlerVersion ?? "—"} />
      </dl>
      {card.workerHealth ? (
        <div className="flex items-center gap-2">
          <SectionLabel>Worker health</SectionLabel>
          <HealthPill level={card.workerHealth.worst} />
          <span className="text-gray-600 dark:text-gray-300">{card.workerHealth.total} worker{card.workerHealth.total === 1 ? "" : "s"}</span>
        </div>
      ) : null}
      {card.instances.length === 0 ? (
        <EmptyState>No live instances found.</EmptyState>
      ) : (
        <Table>
          <THead columns={["Host", "Role", "Version", "Started", "Heartbeat", "Disk"]} />
          <TBody>
            {card.instances.map((instance) => (
              <tr key={instance.key}>
                <Td mono>{instance.hostname}</Td>
                <Td>{instance.role || "—"}</Td>
                <Td mono>{instance.version || "—"}</Td>
                <Td mono>{instance.startedAt || "—"}</Td>
                <Td mono>{instance.lastHeartbeatAt || "—"}</Td>
                <Td>
                  {instance.diskLevel ? (
                    <span className="inline-flex items-center gap-1">
                      <HealthPill level={parseHealthLevel(instance.diskLevel)} />
                      {instance.diskUsedPercent != null ? <span className="font-mono">{instance.diskUsedPercent.toFixed(1)}%</span> : null}
                    </span>
                  ) : "—"}
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

const adminVersionToolCard: ToolCardRenderer = {
  toolName: "admin_version",
  collapsedSummary,
  renderExpanded
}

export default adminVersionToolCard
