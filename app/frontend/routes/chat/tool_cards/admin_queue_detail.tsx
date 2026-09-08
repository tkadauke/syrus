import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_queue_detail (EPIC-293 / JOB-4227). The
// tool reads one SolidQueue tab at a time (active/pending/failed/recurring/
// workers); each tab shares almost nothing shape-wise with the others, so
// this card dispatches on the echoed `tab` field and renders a dense table
// tailored to that tab.
type JobRow = { key: string; id: string; className: string | null; queueName: string | null; createdAt: string | null; claimedAt: string | null }
type FailureRow = { key: string; id: string; createdAt: string | null; className: string | null; exceptionClass: string | null; message: string | null }
type TaskRow = { key: string; taskKey: string; className: string | null; schedule: string | null; lastRunAt: string | null; lastFinishedAt: string | null }
type WorkerRow = { key: string; hostname: string; pid: string | null; queues: string[]; threads: string | null; lastHeartbeatAt: string | null; stale: boolean; status: string | null }
type ProcessRow = { key: string; kind: string | null; hostname: string; pid: string | null; lastHeartbeatAt: string | null; stale: boolean; status: string | null }

type QueueDetailCard =
  | { tab: "active"; jobs: JobRow[] }
  | { tab: "pending"; jobs: JobRow[]; total: number | null }
  | { tab: "failed"; failures: FailureRow[]; since: string | null }
  | { tab: "recurring"; tasks: TaskRow[] }
  | { tab: "workers"; workers: WorkerRow[]; processes: ProcessRow[] }

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => { const name = displayValue(item); return name ? [name] : [] })
}

function parseJobRow(value: unknown, index: number): JobRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    key: `${id}-${index}`,
    id,
    className: displayValue(value.class_name),
    queueName: displayValue(value.queue_name),
    createdAt: displayValue(value.created_at),
    claimedAt: displayValue(value.claimed_at)
  }
}

function parseFailureRow(value: unknown, index: number): FailureRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    key: `${id}-${index}`,
    id,
    createdAt: displayValue(value.created_at),
    className: displayValue(value.class_name),
    exceptionClass: displayValue(value.exception_class),
    message: displayValue(value.message)
  }
}

function parseTaskRow(value: unknown, index: number): TaskRow | null {
  if (!isPlainObject(value)) return null
  const taskKey = displayValue(value.key)
  if (!taskKey) return null

  return {
    key: `${taskKey}-${index}`,
    taskKey,
    className: displayValue(value.class_name),
    schedule: displayValue(value.schedule),
    lastRunAt: displayValue(value.last_run_at),
    lastFinishedAt: displayValue(value.last_finished_at)
  }
}

function parseWorkerRow(value: unknown, index: number): WorkerRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  return {
    key: `${hostname}-${displayValue(value.pid) ?? index}`,
    hostname,
    pid: displayValue(value.pid),
    queues: stringList(value.queues),
    threads: displayValue(value.threads),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    stale: value.stale === true,
    status: displayValue(value.status)
  }
}

function parseProcessRow(value: unknown, index: number): ProcessRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  return {
    key: `${hostname}-${displayValue(value.pid) ?? index}`,
    kind: displayValue(value.kind),
    hostname,
    pid: displayValue(value.pid),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    stale: value.stale === true,
    status: displayValue(value.status)
  }
}

function parseQueueDetail(context: ToolCardContext): QueueDetailCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const tab = displayValue(parsed.tab)
  switch (tab) {
    case "active":
      if (!Array.isArray(parsed.jobs)) return null
      return { tab: "active", jobs: parsed.jobs.flatMap((job, index) => { const row = parseJobRow(job, index); return row ? [row] : [] }) }
    case "pending":
      if (!Array.isArray(parsed.jobs)) return null
      return { tab: "pending", jobs: parsed.jobs.flatMap((job, index) => { const row = parseJobRow(job, index); return row ? [row] : [] }), total: numberValue(parsed.total) }
    case "failed":
      if (!Array.isArray(parsed.failures)) return null
      return { tab: "failed", failures: parsed.failures.flatMap((failure, index) => { const row = parseFailureRow(failure, index); return row ? [row] : [] }), since: displayValue(parsed.since) }
    case "recurring":
      if (!Array.isArray(parsed.tasks)) return null
      return { tab: "recurring", tasks: parsed.tasks.flatMap((task, index) => { const row = parseTaskRow(task, index); return row ? [row] : [] }) }
    case "workers":
      if (!Array.isArray(parsed.workers) || !Array.isArray(parsed.all_processes)) return null
      return {
        tab: "workers",
        workers: parsed.workers.flatMap((worker, index) => { const row = parseWorkerRow(worker, index); return row ? [row] : [] }),
        processes: parsed.all_processes.flatMap((process, index) => { const row = parseProcessRow(process, index); return row ? [row] : [] })
      }
    default:
      return null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseQueueDetail(context)
  if (!card) return null

  switch (card.tab) {
    case "active":
      return `${card.jobs.length} active job${card.jobs.length === 1 ? "" : "s"}`
    case "pending": {
      const count = card.total ?? card.jobs.length
      return `${count} pending job${count === 1 ? "" : "s"}`
    }
    case "failed":
      return `${card.failures.length} failure${card.failures.length === 1 ? "" : "s"}`
    case "recurring":
      return `${card.tasks.length} recurring task${card.tasks.length === 1 ? "" : "s"}`
    case "workers":
      return `${card.workers.length} worker${card.workers.length === 1 ? "" : "s"}, ${card.processes.length} process${card.processes.length === 1 ? "" : "es"}`
  }
}

function StaleBadge({ stale }: { stale: boolean }) {
  return stale ? <StatePill state="stale" tone="warning" /> : <StatePill state="current" tone="success" />
}

function JobsTable({ jobs }: { jobs: JobRow[] }) {
  if (jobs.length === 0) return <EmptyState>No jobs found.</EmptyState>
  return (
    <Table>
      <THead columns={["Id", "Class", "Queue", "Created", "Claimed"]} />
      <TBody>
        {jobs.map((job) => (
          <tr key={job.key}>
            <Td mono>{job.id}</Td>
            <Td maxWidth title={job.className ?? undefined}>{job.className || "—"}</Td>
            <Td>{job.queueName || "—"}</Td>
            <Td mono>{job.createdAt || "—"}</Td>
            <Td mono>{job.claimedAt || "—"}</Td>
          </tr>
        ))}
      </TBody>
    </Table>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseQueueDetail(context)
  if (!card) return null

  if (card.tab === "active") return <CardShell><JobsTable jobs={card.jobs} /></CardShell>

  if (card.tab === "pending") {
    return (
      <CardShell>
        {card.total != null ? <Row label="Total pending" value={String(card.total)} /> : null}
        <JobsTable jobs={card.jobs} />
      </CardShell>
    )
  }

  if (card.tab === "failed") {
    return (
      <CardShell>
        {card.since ? <Row label="Since" value={card.since} /> : null}
        {card.failures.length === 0 ? (
          <EmptyState>No failures found.</EmptyState>
        ) : (
          <Table>
            <THead columns={["Id", "Class", "Exception", "Message", "Created"]} />
            <TBody>
              {card.failures.map((failure) => (
                <tr key={failure.key}>
                  <Td mono>{failure.id}</Td>
                  <Td maxWidth title={failure.className ?? undefined}>{failure.className || "—"}</Td>
                  <Td maxWidth title={failure.exceptionClass ?? undefined}>{failure.exceptionClass || "—"}</Td>
                  <Td maxWidth title={failure.message ?? undefined}>{failure.message || "—"}</Td>
                  <Td mono>{failure.createdAt || "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
      </CardShell>
    )
  }

  if (card.tab === "recurring") {
    return (
      <CardShell>
        {card.tasks.length === 0 ? (
          <EmptyState>No recurring tasks found.</EmptyState>
        ) : (
          <Table>
            <THead columns={["Key", "Class", "Schedule", "Last run", "Last finished"]} />
            <TBody>
              {card.tasks.map((task) => (
                <tr key={task.key}>
                  <Td mono>{task.taskKey}</Td>
                  <Td maxWidth title={task.className ?? undefined}>{task.className || "—"}</Td>
                  <Td mono>{task.schedule || "—"}</Td>
                  <Td mono>{task.lastRunAt || "—"}</Td>
                  <Td mono>{task.lastFinishedAt || "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
      </CardShell>
    )
  }

  return (
    <CardShell>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Workers ({card.workers.length})</div>
      {card.workers.length === 0 ? (
        <EmptyState>No active workers found.</EmptyState>
      ) : (
        <Table>
          <THead columns={["Host", "Pid", "Queues", "Threads", "Heartbeat", "Status"]} />
          <TBody>
            {card.workers.map((worker) => (
              <tr key={worker.key}>
                <Td mono>{worker.hostname}</Td>
                <Td mono>{worker.pid || "—"}</Td>
                <Td maxWidth title={worker.queues.join(", ")}>{worker.queues.join(", ") || "—"}</Td>
                <Td>{worker.threads || "—"}</Td>
                <Td mono>{worker.lastHeartbeatAt || "—"}</Td>
                <Td><StaleBadge stale={worker.stale} /></Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">All processes ({card.processes.length})</div>
      {card.processes.length === 0 ? (
        <EmptyState>No processes found.</EmptyState>
      ) : (
        <Table>
          <THead columns={["Kind", "Host", "Pid", "Heartbeat", "Status"]} />
          <TBody>
            {card.processes.map((process) => (
              <tr key={process.key}>
                <Td>{process.kind || "—"}</Td>
                <Td mono>{process.hostname}</Td>
                <Td mono>{process.pid || "—"}</Td>
                <Td mono>{process.lastHeartbeatAt || "—"}</Td>
                <Td><StaleBadge stale={process.stale} /></Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

const adminQueueDetailToolCard: ToolCardRenderer = {
  toolName: "admin_queue_detail",
  collapsedSummary,
  renderExpanded
}

export default adminQueueDetailToolCard
