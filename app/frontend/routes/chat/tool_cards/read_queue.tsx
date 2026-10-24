import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { useT } from "../../../hooks/useT"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CapabilityBadges, CardShell, displayValue, EmptyState, InternalLink, Row, SectionLabel, StatePill } from "../toolCardUi"

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

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const name = displayValue(item)
    return name ? [name] : []
  })
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

function parseWorker(value: unknown): Worker | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  const pid = displayValue(value.pid)
  if (!hostname || !pid) return null
  return {
    key: `${hostname}-${pid}`,
    hostname,
    pid,
    queues: stringList(value.queues),
    threads: displayValue(value.threads),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    stale: value.stale === true,
    status: displayValue(value.status),
    capabilities: value.capabilities,
    capabilityDiagnostics: diagnostics(value.capability_diagnostics),
    macosDrain: parseMacosDrain(value.macos_worker_drain)
  }
}

function parseQueueCard(context: ToolCardContext): QueueCard | null {
  const parsed = context.parsedResult
  const text = displayValue(parsed) || context.resultBody.trim()
  if (text.startsWith(UNAUTHORIZED_PREFIX))
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
  if (!isPlainObject(parsed)) return null
  const activeWorkers = isPlainObject(parsed.active_workers) ? parsed.active_workers : null
  const pendingJobsValue = isPlainObject(parsed.pending_jobs) ? parsed.pending_jobs : null
  if (!activeWorkers || !pendingJobsValue) return null
  return {
    unauthorized: false,
    unavailable: parsed.unavailable === true,
    error: displayValue(parsed.error),
    workerCount: typeof activeWorkers.count === "number" ? activeWorkers.count : null,
    activeQueues: stringList(activeWorkers.queues),
    workers: Array.isArray(activeWorkers.workers)
      ? activeWorkers.workers.flatMap((worker) => {
          const parsedWorker = parseWorker(worker)
          return parsedWorker ? [parsedWorker] : []
        })
      : [],
    pendingJobs: Object.entries(pendingJobsValue).flatMap(([key, value]): Array<[string, number]> =>
      typeof value === "number" && Number.isFinite(value) ? [[key, value]] : []
    ),
    failedCount: isPlainObject(parsed.failed_jobs) && typeof parsed.failed_jobs.count === "number" ? parsed.failed_jobs.count : null,
    recurringCount: isPlainObject(parsed.recurring_tasks) && typeof parsed.recurring_tasks.count === "number" ? parsed.recurring_tasks.count : null,
    blockedQueues: stringList(parsed.blocked_queues),
    pausedQueues: stringList(parsed.paused_queues)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseQueueCard(context)
  if (!card) return null
  if (card.unauthorized) return i18n.t("chat:tool_card_read_queue_admin_required")
  if (card.unavailable) return i18n.t("chat:tool_card_read_queue_unavailable")
  const workers = i18n.t("chat:tool_card_read_queue_worker_count", { count: card.workerCount ?? 0 })
  const failed = i18n.t("chat:tool_card_read_queue_failed_count", { count: card.failedCount ?? 0 })
  return `${workers}, ${failed}`
}

function QueueList({ label, queues, tone }: { label: string; queues: string[]; tone?: "failure" | "warning" }) {
  if (queues.length === 0) return null
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-1">
        {queues.map((queue) => (tone ? <StatePill key={queue} state={queue} tone={tone} /> : <Badge key={queue}>{queue}</Badge>))}
      </div>
    </div>
  )
}

function ReadQueueCard({ card }: { card: QueueCard }) {
  const { t } = useT("chat")
  if (card.unauthorized) return <EmptyState>{t("tool_card_read_queue_admin_required_body")}</EmptyState>
  if (card.unavailable)
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {t("tool_card_read_queue_unavailable")}
        </div>
        {card.error ? (
          <div className="min-w-0 break-all">
            <MarkdownPreview maxLines={4} text={card.error} title={t("tool_card_read_queue_error_details")} />
          </div>
        ) : null}
      </CardShell>
    )

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label={t("tool_card_read_queue_workers")} value={String(card.workerCount ?? 0)} />
        <Row label={t("tool_card_read_queue_failed_jobs")} value={String(card.failedCount ?? 0)} />
        <Row label={t("tool_card_read_queue_recurring_tasks")} value={String(card.recurringCount ?? 0)} />
      </dl>
      <QueueList label={t("tool_card_read_queue_active_queues")} queues={card.activeQueues} />
      {card.pendingJobs.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_card_read_queue_pending_jobs")}</SectionLabel>
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
          <QueueList label={t("tool_card_read_queue_blocked_queues")} queues={card.blockedQueues} tone="failure" />
          <QueueList label={t("tool_card_read_queue_paused_queues")} queues={card.pausedQueues} tone="warning" />
        </div>
      ) : null}
      {card.workers.length > 0 ? (
        <div>
          <SectionLabel>{t("tool_card_read_queue_workers")}</SectionLabel>
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
                      {worker.macosDrain.forceTerminate ? t("tool_card_read_queue_force_restart") : worker.macosDrain.state}
                      {worker.macosDrain.desiredGitSha ? `: ${worker.macosDrain.desiredGitSha}` : ""}
                      {worker.macosDrain.lastError ? ` · ${worker.macosDrain.lastError}` : ""}
                    </Badge>
                  ) : null}
                </div>
                <dl className="mt-1 grid gap-1 sm:grid-cols-2">
                  <Row label={t("tool_card_read_queue_threads")} value={worker.threads || "—"} />
                  <Row label={t("tool_card_read_queue_last_heartbeat")} value={worker.lastHeartbeatAt || "—"} />
                </dl>
                {worker.capabilityDiagnostics.length > 0 ? (
                  <div className="mt-1 min-w-0">
                    <SectionLabel>{t("tool_card_read_queue_capability_diagnostics")}</SectionLabel>
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
        <EmptyState>{t("tool_card_read_queue_no_workers")}</EmptyState>
      )}
    </CardShell>
  )
}

const readQueueToolCard: ToolCardRenderer = {
  toolName: "read_queue",
  collapsedSummary,
  renderExpanded(context) {
    const card = parseQueueCard(context)
    return card ? <ReadQueueCard card={card} /> : null
  }
}
export default readQueueToolCard

export const examples: ToolCardExample[] = [
  {
    id: "healthy_workers",
    label: i18n.t("chat:tool_card_read_queue_example_healthy"),
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
    label: i18n.t("chat:tool_card_read_queue_example_unavailable"),
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
  { id: "unauthorized", label: i18n.t("chat:tool_card_read_queue_example_unauthorized"), resultBody: "Unauthorized: Admin access required" }
]
