import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CapabilityBadges, CardShell, displayValue, EmptyState, InternalLink, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for read_queue (the Tier 1 tool-card work). Renders a
// compact Solid Queue ops dashboard: worker/failed/recurring counts,
// per-queue pending counts, blocked/paused queues, and stale workers.
type MacosDrain = { state: string; desiredGitSha: string | null; forceTerminate: boolean; lastError: string | null }
type Worker = {
  key: string
  hostname: string
  pid: string
  queues: string[]
  threads: string | null
  lastHeartbeatAt: string | null
  stale: boolean
  status: string | null
  capabilities: unknown
  capabilityDiagnostics: Array<[string, string]>
  macosDrain: MacosDrain | null
}

type QueueCard = {
  unauthorized: boolean
  unavailable: boolean
  error: string | null
  workerCount: number | null
  activeQueues: string[]
  workers: Worker[]
  pendingJobs: Array<[string, number]>
  failedCount: number | null
  recurringCount: number | null
  blockedQueues: string[]
  pausedQueues: string[]
}

const UNAUTHORIZED_PREFIX = "Unauthorized:"

function diagnosticValue(value: unknown): string | null {
  const displayed = displayValue(value)
  if (displayed) return displayed
  if (typeof value === "boolean") return String(value)
  if (value == null) return null
  try {
    return JSON.stringify(value)
  } catch {
    return null
  }
}

function diagnostics(value: unknown): Array<[string, string]> {
  if (!isPlainObject(value)) return []
  return Object.entries(value).flatMap(([key, item]): Array<[string, string]> => {
    const displayed = diagnosticValue(item)
    return displayed ? [[key, displayed]] : []
  })
}

function parseWorker(value: unknown): Worker | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  const pid = displayValue(value.pid)
  if (!hostname || !pid) return null

  return {
    key: `${hostname}-${pid}`,
    hostname,
    pid,
    queues: Array.isArray(value.queues)
      ? value.queues.flatMap((queue) => {
          const name = displayValue(queue)
          return name ? [name] : []
        })
      : [],
    threads: displayValue(value.threads),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    stale: value.stale === true,
    status: displayValue(value.status),
    capabilities: value.capabilities,
    capabilityDiagnostics: diagnostics(value.capability_diagnostics),
    macosDrain: parseMacosDrain(value.macos_worker_drain)
  }
}

function parseMacosDrain(value: unknown): MacosDrain | null {
  if (!isPlainObject(value)) return null
  const state = displayValue(value.state)
  if (!state || state === "none") return null
  const desiredVersion = isPlainObject(value.desired_version) ? value.desired_version : null

  return {
    state,
    desiredGitSha: displayValue(value.desired_git_sha) || displayValue(desiredVersion?.git_sha),
    forceTerminate: value.force_terminate === true,
    lastError: displayValue(value.last_error)
  }
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const name = displayValue(item)
    return name ? [name] : []
  })
}

function parseQueueCard(context: ToolCardContext): QueueCard | null {
  const parsed = context.parsedResult
  const text = displayValue(parsed) || context.resultBody.trim()
  if (text.startsWith(UNAUTHORIZED_PREFIX)) {
    return {
      unauthorized: true,
      unavailable: false,
      error: null,
      workerCount: null,
      activeQueues: [],
      workers: [],
      pendingJobs: [],
      failedCount: null,
      recurringCount: null,
      blockedQueues: [],
      pausedQueues: []
    }
  }
  if (!isPlainObject(parsed)) return null

  const activeWorkers = isPlainObject(parsed.active_workers) ? parsed.active_workers : null
  const pendingJobsValue = isPlainObject(parsed.pending_jobs) ? parsed.pending_jobs : null
  if (!activeWorkers || !pendingJobsValue) return null

  const pendingJobs = Object.entries(pendingJobsValue).flatMap(([key, value]): Array<[string, number]> =>
    typeof value === "number" && Number.isFinite(value) ? [[key, value]] : []
  )

  return {
    unauthorized: false,
    unavailable: parsed.unavailable === true,
    error: displayValue(parsed.error),
    workerCount: typeof activeWorkers.count === "number" ? activeWorkers.count : null,
    activeQueues: stringList(activeWorkers.queues),
    workers: Array.isArray(activeWorkers.workers)
      ? activeWorkers.workers.flatMap((worker) => {
          const parsed = parseWorker(worker)
          return parsed ? [parsed] : []
        })
      : [],
    pendingJobs,
    failedCount: isPlainObject(parsed.failed_jobs) && typeof parsed.failed_jobs.count === "number" ? parsed.failed_jobs.count : null,
    recurringCount: isPlainObject(parsed.recurring_tasks) && typeof parsed.recurring_tasks.count === "number" ? parsed.recurring_tasks.count : null,
    blockedQueues: stringList(parsed.blocked_queues),
    pausedQueues: stringList(parsed.paused_queues)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseQueueCard(context)
  if (!card) return null
  if (card.unauthorized) return "Admin access required"
  if (card.unavailable) return "Queue snapshot unavailable"
  return `${card.workerCount ?? 0} worker${card.workerCount === 1 ? "" : "s"}, ${card.failedCount ?? 0} failed job${card.failedCount === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseQueueCard(context)
  if (!card) return null

  if (card.unauthorized) {
    return <EmptyState>Admin access is required to read queue health.</EmptyState>
  }

  if (card.unavailable) {
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          Queue snapshot unavailable
        </div>
        {card.error ? (
          <div className="min-w-0 break-all">
            <MarkdownPreview maxLines={4} text={card.error} title="Error details" />
          </div>
        ) : null}
      </CardShell>
    )
  }

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label="Workers" value={String(card.workerCount ?? 0)} />
        <Row label="Failed jobs" value={String(card.failedCount ?? 0)} />
        <Row label="Recurring tasks" value={String(card.recurringCount ?? 0)} />
      </dl>
      {card.activeQueues.length > 0 ? (
        <div>
          <SectionLabel>Active queues</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.activeQueues.map((queue) => (
              <Badge key={queue}>{queue}</Badge>
            ))}
          </div>
        </div>
      ) : null}
      {card.pendingJobs.length > 0 ? (
        <div>
          <SectionLabel>Pending jobs</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.pendingJobs.map(([queue, count]) => (
              <Badge key={queue}>
                {queue}: {count}
              </Badge>
            ))}
          </div>
        </div>
      ) : null}
      {card.blockedQueues.length > 0 || card.pausedQueues.length > 0 ? (
        <div className="flex flex-wrap gap-3">
          {card.blockedQueues.length > 0 ? (
            <div>
              <SectionLabel>Blocked queues</SectionLabel>
              <div className="mt-1 flex flex-wrap gap-1">
                {card.blockedQueues.map((queue) => (
                  <StatePill key={queue} state={queue} tone="failure" />
                ))}
              </div>
            </div>
          ) : null}
          {card.pausedQueues.length > 0 ? (
            <div>
              <SectionLabel>Paused queues</SectionLabel>
              <div className="mt-1 flex flex-wrap gap-1">
                {card.pausedQueues.map((queue) => (
                  <StatePill key={queue} state={queue} tone="warning" />
                ))}
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
      {card.workers.length > 0 ? (
        <div>
          <SectionLabel>Workers</SectionLabel>
          <ul className="mt-1 space-y-1">
            {card.workers.map((worker) => (
              <li className="min-w-0 rounded border border-border px-2 py-1.5" key={worker.key}>
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <InternalLink className="inline-flex min-h-11 min-w-0 items-center break-all" href="/admin/queue/workers">
                    {worker.hostname}:{worker.pid}
                  </InternalLink>
                  {worker.status ? <StatePill state={worker.status} /> : null}
                  {worker.stale ? <StatePill state="stale" tone="warning" /> : null}
                  {worker.queues.map((queue) => (
                    <Badge key={queue}>{queue}</Badge>
                  ))}
                  <CapabilityBadges capabilities={worker.capabilities} />
                  {worker.macosDrain ? (
                    <Badge>
                      {worker.macosDrain.forceTerminate ? "force restart" : worker.macosDrain.state}
                      {worker.macosDrain.desiredGitSha ? `: ${worker.macosDrain.desiredGitSha}` : ""}
                      {worker.macosDrain.lastError ? ` · ${worker.macosDrain.lastError}` : ""}
                    </Badge>
                  ) : null}
                </div>
                <dl className="mt-1 grid gap-1 sm:grid-cols-2">
                  <Row label="Threads" value={worker.threads || "—"} />
                  <Row label="Last heartbeat" value={worker.lastHeartbeatAt || "—"} />
                </dl>
                {worker.capabilityDiagnostics.length > 0 ? (
                  <div className="mt-1 min-w-0">
                    <SectionLabel>Capability diagnostics</SectionLabel>
                    <div className="mt-1 flex min-w-0 flex-wrap gap-1">
                      {worker.capabilityDiagnostics.map(([key, value]) => (
                        <Badge key={key}>
                          <span className="break-all">
                            {key}: {value}
                          </span>
                        </Badge>
                      ))}
                    </div>
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        </div>
      ) : (
        <EmptyState>No active workers found.</EmptyState>
      )}
    </CardShell>
  )
}

const readQueueToolCard: ToolCardRenderer = {
  toolName: "read_queue",
  collapsedSummary,
  renderExpanded
}

export default readQueueToolCard

export const examples: ToolCardExample[] = [
  {
    id: "healthy_workers",
    label: "Healthy workers with capability details",
    parsedResult: {
      active_workers: {
        count: 1,
        queues: ["chat", "runs"],
        workers: [
          {
            hostname: "worker-1",
            pid: 42,
            queues: ["chat", "runs"],
            threads: 3,
            last_heartbeat_at: "2026-01-01T00:00:00Z",
            stale: false,
            status: "current",
            capabilities: { os: ["linux"] },
            capability_diagnostics: { docker: true },
            macos_worker_drain: null
          }
        ]
      },
      pending_jobs: { chat: 1, runs: 2 },
      failed_jobs: { count: 0 },
      recurring_tasks: { count: 4 },
      blocked_queues: [],
      paused_queues: []
    }
  },
  {
    id: "unavailable",
    label: "Queue snapshot unavailable",
    parsedResult: {
      active_workers: { count: 0, queues: [], workers: [] },
      pending_jobs: {},
      failed_jobs: { count: 0 },
      recurring_tasks: { count: 0 },
      blocked_queues: [],
      paused_queues: [],
      unavailable: true,
      error: "**Database connection failed.**\n\nThe queue snapshot could not be loaded. ".repeat(20)
    }
  },
  { id: "unauthorized", label: "Admin access required", resultBody: "Unauthorized: Admin access required" }
]
