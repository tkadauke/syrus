import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, Disclosure, displayValue, EmptyState, numberValue, Row, SectionLabel } from "../toolCardUi"
import { formatPercent, HealthPill, parseHealthLevel, Table, TBody, Td, THead, type HealthLevel } from "../adminToolCard"

// Core-owned tool card for read_worker_health (EPIC-293 / JOB-4227). Renders
// the live per-worker rollup (health level, pressure indicators, timing) as
// a dense table, and a per-host trend summary (sample/warning/critical
// counts over 1h and 24h) behind a disclosure -- the full minute-bucket and
// raw-sample history stays in "Raw details" only.
type CurrentWorker = {
  key: string
  hostname: string
  role: string | null
  version: string | null
  stale: boolean
  healthLevel: HealthLevel
  healthReasons: string[]
  cpuPercent: number | null
  memoryPercent: number | null
  diskPercent: number | null
  ioPressureSome: number | null
  lastHeartbeatAt: string | null
}

type WindowSummary = { sampleCount: number; warningCount: number; criticalCount: number }

type HostHistoryRow = { key: string; hostname: string; status: string | null; window1h: WindowSummary | null; window24h: WindowSummary | null }

type WorkerHealthCard = {
  since: string | null
  until: string | null
  current: CurrentWorker[]
  hosts: HostHistoryRow[]
}

function parseReasons(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((reason) => { const text = displayValue(reason); return text ? [text] : [] })
}

function parseCurrentWorker(value: unknown, index: number): CurrentWorker | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  const health = isPlainObject(value.health) ? value.health : null
  const sample = isPlainObject(value.sample) ? value.sample : null

  return {
    key: `${hostname}-${index}`,
    hostname,
    role: displayValue(value.role),
    version: displayValue(value.version),
    stale: value.stale === true,
    healthLevel: parseHealthLevel(health?.level),
    healthReasons: parseReasons(health?.reasons),
    cpuPercent: sample && typeof sample.cpu_used_percent === "number" ? sample.cpu_used_percent : null,
    memoryPercent: sample && typeof sample.memory_used_percent === "number" ? sample.memory_used_percent : null,
    diskPercent: sample && typeof sample.data_root_used_percent === "number" ? sample.data_root_used_percent : null,
    ioPressureSome: sample && typeof sample.io_pressure_some === "number" ? sample.io_pressure_some : null,
    lastHeartbeatAt: displayValue(value.last_heartbeat_at)
  }
}

function parseWindowSummary(value: unknown): WindowSummary | null {
  if (!isPlainObject(value)) return null
  const sampleCount = numberValue(value.sample_count)
  if (sampleCount == null) return null

  return { sampleCount, warningCount: numberValue(value.warning_count) ?? 0, criticalCount: numberValue(value.critical_count) ?? 0 }
}

function parseHostRow(value: unknown, index: number): HostHistoryRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  const windows = isPlainObject(value.windows) ? value.windows : null

  return {
    key: `${hostname}-${index}`,
    hostname,
    status: displayValue(value.status),
    window1h: windows ? parseWindowSummary(windows["1h"]) : null,
    window24h: windows ? parseWindowSummary(windows["24h"]) : null
  }
}

function parseWorkerHealth(context: ToolCardContext): WorkerHealthCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.current)) return null

  const range = isPlainObject(parsed.range) ? parsed.range : null

  return {
    since: range ? displayValue(range.since) : null,
    until: range ? displayValue(range.until) : null,
    current: parsed.current.flatMap((worker, index) => { const row = parseCurrentWorker(worker, index); return row ? [row] : [] }),
    hosts: Array.isArray(parsed.hosts) ? parsed.hosts.flatMap((host, index) => { const row = parseHostRow(host, index); return row ? [row] : [] }) : []
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseWorkerHealth(context)
  if (!card) return null

  const unhealthy = card.current.filter((worker) => worker.healthLevel !== "ok").length
  if (card.current.length === 0) return "No live workers"
  return unhealthy > 0
    ? `${unhealthy} of ${card.current.length} worker${card.current.length === 1 ? "" : "s"} need attention`
    : `${card.current.length} worker${card.current.length === 1 ? "" : "s"} healthy`
}

function WindowCell({ window }: { window: WindowSummary | null }) {
  if (!window) return <>—</>
  if (window.sampleCount === 0) return <span className="text-gray-400 dark:text-gray-500">no samples</span>
  return <span>{window.sampleCount} samples{window.criticalCount > 0 ? `, ${window.criticalCount} critical` : window.warningCount > 0 ? `, ${window.warningCount} warning` : ""}</span>
}

function renderExpanded(context: ToolCardContext) {
  const card = parseWorkerHealth(context)
  if (!card) return null

  return (
    <CardShell>
      {card.since && card.until ? <Row label="Range" value={`${card.since} → ${card.until}`} /> : null}
      {card.current.length === 0 ? (
        <EmptyState>No live workers found.</EmptyState>
      ) : (
        <Table>
          <THead columns={["Host", "Role", "Health", "CPU", "Memory", "Disk", "IO pressure", "Heartbeat"]} />
          <TBody>
            {card.current.map((worker) => (
              <tr key={worker.key}>
                <Td mono>{worker.hostname}</Td>
                <Td>{worker.role || "—"}</Td>
                <Td>
                  <span className="inline-flex items-center gap-1" title={worker.healthReasons.join("; ") || undefined}>
                    <HealthPill level={worker.healthLevel} />
                    {worker.stale ? <span className="text-2xs text-gray-500 dark:text-gray-400">(stale)</span> : null}
                  </span>
                </Td>
                <Td mono>{formatPercent(worker.cpuPercent)}</Td>
                <Td mono>{formatPercent(worker.memoryPercent)}</Td>
                <Td mono>{formatPercent(worker.diskPercent)}</Td>
                <Td mono>{formatPercent(worker.ioPressureSome)}</Td>
                <Td mono>{worker.lastHeartbeatAt || "—"}</Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
      {card.hosts.length > 0 ? (
        <Disclosure label="Host trend history">
          <div>
            <SectionLabel>Warning/critical samples by window</SectionLabel>
            <Table>
              <THead columns={["Host", "Status", "Last 1h", "Last 24h"]} />
              <TBody>
                {card.hosts.map((host) => (
                  <tr key={host.key}>
                    <Td mono>{host.hostname}</Td>
                    <Td>{host.status || "—"}</Td>
                    <Td><WindowCell window={host.window1h} /></Td>
                    <Td><WindowCell window={host.window24h} /></Td>
                  </tr>
                ))}
              </TBody>
            </Table>
          </div>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

const readWorkerHealthToolCard: ToolCardRenderer = {
  toolName: "read_worker_health",
  collapsedSummary,
  renderExpanded
}

export default readWorkerHealthToolCard
