import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, Row, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for read_queue (EPIC-291 / JOB-4221). Renders a
// compact Solid Queue ops dashboard: worker/failed/recurring counts,
// per-queue pending counts, blocked/paused queues, and stale workers.
type Worker = { key: string; hostname: string; pid: string; queues: string[]; stale: boolean }

type QueueCard = {
  unavailable: boolean
  error: string | null
  workerCount: number | null
  workers: Worker[]
  pendingJobs: Array<[string, number]>
  failedCount: number | null
  recurringCount: number | null
  blockedQueues: string[]
  pausedQueues: string[]
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
    queues: Array.isArray(value.queues) ? value.queues.flatMap((queue) => { const name = displayValue(queue); return name ? [name] : [] }) : [],
    stale: value.stale === true
  }
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => { const name = displayValue(item); return name ? [name] : [] })
}

function parseQueueCard(context: ToolCardContext): QueueCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const activeWorkers = isPlainObject(parsed.active_workers) ? parsed.active_workers : null
  const pendingJobsValue = isPlainObject(parsed.pending_jobs) ? parsed.pending_jobs : null
  if (!activeWorkers || !pendingJobsValue) return null

  const pendingJobs = Object.entries(pendingJobsValue).flatMap(([key, value]): Array<[string, number]> =>
    typeof value === "number" && Number.isFinite(value) ? [[key, value]] : []
  )

  return {
    unavailable: parsed.unavailable === true,
    error: displayValue(parsed.error),
    workerCount: typeof activeWorkers.count === "number" ? activeWorkers.count : null,
    workers: Array.isArray(activeWorkers.workers) ? activeWorkers.workers.flatMap((worker) => { const parsed = parseWorker(worker); return parsed ? [parsed] : [] }) : [],
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
  if (card.unavailable) return "Queue snapshot unavailable"
  return `${card.workerCount ?? 0} worker${card.workerCount === 1 ? "" : "s"}, ${card.failedCount ?? 0} failed job${card.failedCount === 1 ? "" : "s"}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseQueueCard(context)
  if (!card) return null

  if (card.unavailable) {
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          Queue snapshot unavailable
        </div>
        {card.error ? <div className="font-mono text-2xs text-gray-500 dark:text-gray-400">{card.error}</div> : null}
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
      {card.pendingJobs.length > 0 ? (
        <div>
          <SectionLabel>Pending jobs</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.pendingJobs.map(([queue, count]) => (
              <Badge key={queue}>{queue}: {count}</Badge>
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
                {card.blockedQueues.map((queue) => <StatePill key={queue} state={queue} tone="failure" />)}
              </div>
            </div>
          ) : null}
          {card.pausedQueues.length > 0 ? (
            <div>
              <SectionLabel>Paused queues</SectionLabel>
              <div className="mt-1 flex flex-wrap gap-1">
                {card.pausedQueues.map((queue) => <StatePill key={queue} state={queue} tone="warning" />)}
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
              <li className="flex flex-wrap items-center gap-2" key={worker.key}>
                <span className="font-mono text-gray-700 dark:text-gray-300">{worker.hostname}:{worker.pid}</span>
                {worker.queues.map((queue) => <Badge key={queue}>{queue}</Badge>)}
                {worker.stale ? <StatePill state="stale" tone="warning" /> : null}
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </CardShell>
  )
}

const readQueueToolCard: ToolCardRenderer = {
  toolName: "read_queue",
  collapsedSummary,
  renderExpanded
}

export default readQueueToolCard
