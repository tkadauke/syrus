import i18n from "../../../i18n"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { redactToolCardText, redactToolCardValue } from "../../../toolCardSecurity"
import { TextPreview } from "../toolCardMarkdown"
import { CapabilityBadges, CardShell, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

// Core-owned tool card for admin_queue_detail (the tool-card work). The
// tool reads one SolidQueue tab at a time (active/pending/failed/recurring/
// workers); each tab shares almost nothing shape-wise with the others, so
// this card dispatches on the echoed `tab` field and renders a dense table
// tailored to that tab.
type JobRow = {
  key: string
  id: string
  className: string | null
  queueName: string | null
  priority: string | null
  arguments: string | null
  createdAt: string | null
  scheduledAt: string | null
  claimedAt: string | null
  readyAt: string | null
}
type FailureRow = {
  key: string
  id: string
  jobId: string | null
  createdAt: string | null
  className: string | null
  priority: string | null
  scheduledAt: string | null
  arguments: string | null
  exceptionClass: string | null
  message: string | null
}
type TaskRow = { key: string; taskKey: string; className: string | null; schedule: string | null; lastRunAt: string | null; lastFinishedAt: string | null }
type MacosDrain = { state: string; desiredGitSha: string | null; forceTerminate: boolean; lastError: string | null }
type WorkerRow = {
  key: string
  hostname: string
  pid: string | null
  queues: string[]
  threads: string | null
  lastHeartbeatAt: string | null
  stale: boolean
  status: string | null
  capabilities: unknown
  capabilityDiagnostics: string | null
  macosDrain: MacosDrain | null
}
type ProcessRow = {
  key: string
  kind: string | null
  hostname: string
  pid: string | null
  lastHeartbeatAt: string | null
  stale: boolean
  status: string | null
  capabilities: unknown
  capabilityDiagnostics: string | null
  macosDrain: MacosDrain | null
}

type ResultMetadata = { pagination: unknown; sort: unknown; filter: unknown; controls: unknown; smartFolders: unknown; activeSmartFolderId: string | null }

type QueueDetailCard =
  | ({ tab: "active"; jobs: JobRow[]; total: number | null } & ResultMetadata)
  | ({ tab: "pending"; jobs: JobRow[]; total: number | null } & ResultMetadata)
  | ({ tab: "failed"; failures: FailureRow[]; since: string | null; total: number | null } & ResultMetadata)
  | { tab: "recurring"; tasks: TaskRow[]; sort: unknown }
  | { tab: "workers"; workers: WorkerRow[]; processes: ProcessRow[]; sort: unknown; workerHealth: unknown }

function serialized(value: unknown): string | null {
  if (value == null) return null
  const redacted = redactToolCardValue(value)
  if (typeof redacted === "string") return redactToolCardText(redacted)
  try {
    return JSON.stringify(redacted, null, 2)
  } catch {
    return displayValue(redacted)
  }
}

function resultMetadata(parsed: Record<string, unknown>): ResultMetadata {
  return {
    pagination: parsed.pagination,
    sort: parsed.sort,
    filter: parsed.filter,
    controls: parsed.controls,
    smartFolders: parsed.smart_folders,
    activeSmartFolderId: displayValue(parsed.active_smart_folder_id)
  }
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const name = displayValue(item)
    return name ? [name] : []
  })
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
    priority: displayValue(value.priority),
    arguments: serialized(value.arguments),
    createdAt: displayValue(value.created_at),
    scheduledAt: displayValue(value.scheduled_at),
    claimedAt: displayValue(value.claimed_at),
    readyAt: displayValue(value.ready_at)
  }
}

function parseFailureRow(value: unknown, index: number): FailureRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    key: `${id}-${index}`,
    id,
    jobId: displayValue(value.job_id),
    createdAt: displayValue(value.created_at),
    className: displayValue(value.class_name),
    priority: displayValue(value.priority),
    scheduledAt: displayValue(value.scheduled_at),
    arguments: serialized(value.arguments),
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
    status: displayValue(value.status),
    capabilities: value.capabilities,
    capabilityDiagnostics: serialized(value.capability_diagnostics),
    macosDrain: parseMacosDrain(value.macos_worker_drain)
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
    status: displayValue(value.status),
    capabilities: value.capabilities,
    capabilityDiagnostics: serialized(value.capability_diagnostics),
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

function parseQueueDetail(context: ToolCardContext): QueueDetailCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const tab = displayValue(parsed.tab)
  switch (tab) {
    case "active":
      if (!Array.isArray(parsed.jobs)) return null
      return {
        tab: "active",
        jobs: parsed.jobs.flatMap((job, index) => {
          const row = parseJobRow(job, index)
          return row ? [row] : []
        }),
        total: numberValue(parsed.total),
        ...resultMetadata(parsed)
      }
    case "pending":
      if (!Array.isArray(parsed.jobs)) return null
      return {
        tab: "pending",
        jobs: parsed.jobs.flatMap((job, index) => {
          const row = parseJobRow(job, index)
          return row ? [row] : []
        }),
        total: numberValue(parsed.total),
        ...resultMetadata(parsed)
      }
    case "failed":
      if (!Array.isArray(parsed.failures)) return null
      return {
        tab: "failed",
        failures: parsed.failures.flatMap((failure, index) => {
          const row = parseFailureRow(failure, index)
          return row ? [row] : []
        }),
        since: displayValue(parsed.since),
        total: numberValue(parsed.total),
        ...resultMetadata(parsed)
      }
    case "recurring":
      if (!Array.isArray(parsed.tasks)) return null
      return {
        tab: "recurring",
        tasks: parsed.tasks.flatMap((task, index) => {
          const row = parseTaskRow(task, index)
          return row ? [row] : []
        }),
        sort: parsed.sort
      }
    case "workers":
      if (!Array.isArray(parsed.workers) || !Array.isArray(parsed.all_processes)) return null
      return {
        tab: "workers",
        workers: parsed.workers.flatMap((worker, index) => {
          const row = parseWorkerRow(worker, index)
          return row ? [row] : []
        }),
        processes: parsed.all_processes.flatMap((process, index) => {
          const row = parseProcessRow(process, index)
          return row ? [row] : []
        }),
        sort: parsed.sort,
        workerHealth: parsed.worker_health
      }
    default:
      return null
  }
}

function collapsedSummary(context: ToolCardContext) {
  const inputTab = displayValue(context.input?.tab)
  if (context.resultError) return inputTab ? i18n.t("chat:queue_named_failed", { name: inputTab }) : i18n.t("chat:ops_queue_detail_failed_56fae6")
  const card = parseQueueDetail(context)
  if (!card) return null

  switch (card.tab) {
    case "active":
      return i18n.t("chat:active_job_count", { count: card.total ?? card.jobs.length })
    case "pending": {
      const count = card.total ?? card.jobs.length
      return i18n.t("chat:pending_job_count", { count })
    }
    case "failed":
      return i18n.t("chat:failure_count", { count: card.total ?? card.failures.length })
    case "recurring":
      return i18n.t("chat:recurring_task_count", { count: card.tasks.length })
    case "workers":
      return `${i18n.t("chat:worker_count", { count: card.workers.length })}, ${i18n.t("chat:all_process_count", { count: card.processes.length })}`
  }
}

function StaleBadge({ stale }: { stale: boolean }) {
  return stale ? <StatePill state="stale" tone="warning" /> : <StatePill state="current" tone="success" />
}

function MacosDrainCell({ drain }: { drain: MacosDrain | null }) {
  if (!drain) return <>—</>
  const state = drain.forceTerminate ? "force restart" : drain.state
  const suffix = [drain.desiredGitSha, drain.lastError].filter(Boolean).join(" · ")
  return (
    <span>
      {state}
      {suffix ? ` · ${suffix}` : ""}
    </span>
  )
}

function ArgumentsPreview({ text }: { text: string | null }) {
  return text ? <TextPreview maxLines={3} modalLabel={i18n.t("chat:ops_full_job_arguments_c3d19a")} text={text} /> : <>—</>
}

function JobsTable({ jobs, pending = false }: { jobs: JobRow[]; pending?: boolean }) {
  if (jobs.length === 0) return <EmptyState>{i18n.t("chat:ops_no_jobs_found_be43a9")}</EmptyState>
  return (
    <Table responsive>
      <THead
        columns={[
          "Id",
          i18n.t("chat:ops_class_41ff35"),
          i18n.t("chat:ops_queue_d325fc"),
          i18n.t("chat:ops_priority_886cbf"),
          i18n.t("chat:ops_arguments_cbb9fa"),
          i18n.t("chat:ops_created_accf40"),
          i18n.t("chat:ops_scheduled_1cd1bd"),
          pending ? i18n.t("chat:ops_ready_20c7c5") : i18n.t("chat:ops_claimed_83c878")
        ]}
      />
      <TBody>
        {jobs.map((job) => (
          <tr key={job.key}>
            <Td mono>{job.id}</Td>
            <Td maxWidth title={job.className ?? undefined}>
              {job.className || "—"}
            </Td>
            <Td>{job.queueName || "—"}</Td>
            <Td mono>{job.priority || "—"}</Td>
            <Td wrap>
              <ArgumentsPreview text={job.arguments} />
            </Td>
            <Td mono>{job.createdAt || "—"}</Td>
            <Td mono>{job.scheduledAt || "—"}</Td>
            <Td mono>{(pending ? job.readyAt : job.claimedAt) || "—"}</Td>
          </tr>
        ))}
      </TBody>
    </Table>
  )
}

function TruncationNotice({ shown, total }: { shown: number; total: number | null }) {
  if (total == null || total <= shown) return null
  return (
    <div className="text-2xs text-text-secondary">
      Showing first {shown} of {total}; this tool returns the first 100 only.
    </div>
  )
}

function Metadata({ values }: { values: Array<[string, unknown]> }) {
  const present = values.flatMap(([label, value]) => {
    const text = value === null ? "null" : serialized(value)
    return text ? [[label, text] as const] : []
  })
  if (present.length === 0) return null
  return (
    <details className="rounded-[var(--radius-panel)] border border-border bg-surface px-2 py-1">
      <summary className="cursor-pointer text-2xs font-semibold uppercase text-text-muted">{i18n.t("chat:ops_result_metadata_92881a")}</summary>
      <div className="mt-2 space-y-2">
        {present.map(([label, text]) => (
          <TextPreview key={label} maxLines={4} text={text} title={label} />
        ))}
      </div>
    </details>
  )
}

function RequestTab({ context, resultTab }: { context: ToolCardContext; resultTab?: string }) {
  const requested = displayValue(context.input?.tab)
  return (
    <div className="grid gap-2 sm:grid-cols-2">
      <Row label={i18n.t("chat:ops_requested_tab_ebefbf")} value={requested || "—"} />
      {resultTab ? <Row label={i18n.t("chat:ops_result_tab_731a3e")} value={resultTab} /> : null}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <RequestTab context={context} />
        <TextPreview maxLines={6} text={redactToolCardText(context.resultBody)} title={i18n.t("chat:ops_error_7f2f6a")} />
      </CardShell>
    )
  const card = parseQueueDetail(context)
  if (!card) return null

  if (card.tab === "active")
    return (
      <CardShell>
        <RequestTab context={context} resultTab={card.tab} />
        <TruncationNotice shown={card.jobs.length} total={card.total} />
        <JobsTable jobs={card.jobs} />
        <Metadata
          values={[
            [i18n.t("chat:ops_pagination_100325"), card.pagination],
            [i18n.t("chat:ops_sort_adc4e9"), card.sort],
            [i18n.t("chat:ops_filter_d7decf"), card.filter],
            [i18n.t("chat:ops_controls_bee75c"), card.controls],
            [i18n.t("chat:ops_smart_folders_7ee466"), card.smartFolders],
            [i18n.t("chat:ops_active_smart_folder_id_9898bd"), card.activeSmartFolderId]
          ]}
        />
      </CardShell>
    )

  if (card.tab === "pending") {
    return (
      <CardShell>
        <RequestTab context={context} resultTab={card.tab} />
        {card.total != null ? <Row label={i18n.t("chat:ops_total_pending_7dd598")} value={String(card.total)} /> : null}
        <TruncationNotice shown={card.jobs.length} total={card.total} />
        <JobsTable jobs={card.jobs} pending />
        <Metadata
          values={[
            [i18n.t("chat:ops_pagination_100325"), card.pagination],
            [i18n.t("chat:ops_sort_adc4e9"), card.sort],
            [i18n.t("chat:ops_filter_d7decf"), card.filter],
            [i18n.t("chat:ops_controls_bee75c"), card.controls],
            [i18n.t("chat:ops_smart_folders_7ee466"), card.smartFolders],
            [i18n.t("chat:ops_active_smart_folder_id_9898bd"), card.activeSmartFolderId]
          ]}
        />
      </CardShell>
    )
  }

  if (card.tab === "failed") {
    return (
      <CardShell>
        <RequestTab context={context} resultTab={card.tab} />
        {card.since ? <Row label={i18n.t("chat:ops_since_22a4ed")} value={card.since} /> : null}
        <TruncationNotice shown={card.failures.length} total={card.total} />
        {card.failures.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_failures_found_63222e")}</EmptyState>
        ) : (
          <Table responsive>
            <THead
              columns={[
                "Id",
                "Job",
                i18n.t("chat:ops_class_41ff35"),
                i18n.t("chat:ops_priority_886cbf"),
                i18n.t("chat:ops_scheduled_1cd1bd"),
                i18n.t("chat:ops_arguments_cbb9fa"),
                i18n.t("chat:ops_exception_20049b"),
                i18n.t("chat:ops_message_68f414"),
                i18n.t("chat:ops_created_accf40")
              ]}
            />
            <TBody>
              {card.failures.map((failure) => (
                <tr key={failure.key}>
                  <Td mono>{failure.id}</Td>
                  <Td mono>{failure.jobId || "—"}</Td>
                  <Td maxWidth title={failure.className ?? undefined}>
                    {failure.className || "—"}
                  </Td>
                  <Td mono>{failure.priority || "—"}</Td>
                  <Td mono>{failure.scheduledAt || "—"}</Td>
                  <Td wrap>
                    <ArgumentsPreview text={failure.arguments} />
                  </Td>
                  <Td wrap>
                    {failure.exceptionClass ? (
                      <TextPreview maxLines={3} modalLabel={i18n.t("chat:ops_full_exception_class_da971f")} text={failure.exceptionClass} />
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td wrap>
                    {failure.message ? <TextPreview maxLines={3} modalLabel={i18n.t("chat:ops_full_failure_message_5b2379")} text={failure.message} /> : "—"}
                  </Td>
                  <Td mono>{failure.createdAt || "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
        <Metadata
          values={[
            [i18n.t("chat:ops_pagination_100325"), card.pagination],
            [i18n.t("chat:ops_sort_adc4e9"), card.sort],
            [i18n.t("chat:ops_filter_d7decf"), card.filter],
            [i18n.t("chat:ops_controls_bee75c"), card.controls],
            [i18n.t("chat:ops_smart_folders_7ee466"), card.smartFolders],
            [i18n.t("chat:ops_active_smart_folder_id_9898bd"), card.activeSmartFolderId]
          ]}
        />
      </CardShell>
    )
  }

  if (card.tab === "recurring") {
    return (
      <CardShell>
        <RequestTab context={context} resultTab={card.tab} />
        {card.tasks.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_recurring_tasks_found_d9c892")}</EmptyState>
        ) : (
          <Table responsive>
            <THead
              columns={[
                "Key",
                i18n.t("chat:ops_class_41ff35"),
                i18n.t("chat:ops_schedule_0a8ada"),
                i18n.t("chat:ops_last_run_333c63"),
                i18n.t("chat:ops_last_finished_a8d1cb")
              ]}
            />
            <TBody>
              {card.tasks.map((task) => (
                <tr key={task.key}>
                  <Td mono>{task.taskKey}</Td>
                  <Td maxWidth title={task.className ?? undefined}>
                    {task.className || "—"}
                  </Td>
                  <Td mono>{task.schedule || "—"}</Td>
                  <Td mono>{task.lastRunAt || "—"}</Td>
                  <Td mono>{task.lastFinishedAt || "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        )}
        <Metadata values={[[i18n.t("chat:ops_sort_adc4e9"), card.sort]]} />
      </CardShell>
    )
  }

  return (
    <CardShell>
      <RequestTab context={context} resultTab={card.tab} />
      <SectionLabel>{i18n.t("chat:worker_count", { count: card.workers.length })}</SectionLabel>
      {card.workers.length === 0 ? (
        <EmptyState>{i18n.t("chat:ops_no_active_workers_found_7970c5")}</EmptyState>
      ) : (
        <Table responsive>
          <THead
            columns={[
              i18n.t("chat:ops_host_3960ec"),
              "Pid",
              i18n.t("chat:ops_queues_83dbc3"),
              i18n.t("chat:ops_capabilities_ca09c5"),
              i18n.t("chat:ops_diagnostics_3af227"),
              i18n.t("chat:ops_mac_update_f41288"),
              i18n.t("chat:ops_threads_bb12e8"),
              i18n.t("chat:ops_heartbeat_eb4d41"),
              i18n.t("chat:ops_status_bae7d5")
            ]}
          />
          <TBody>
            {card.workers.map((worker) => (
              <tr key={worker.key}>
                <Td mono>
                  <InternalLink href="/admin/queue/workers">{worker.hostname}</InternalLink>
                </Td>
                <Td mono>{worker.pid || "—"}</Td>
                <Td maxWidth title={worker.queues.join(", ")}>
                  {worker.queues.join(", ") || "—"}
                </Td>
                <Td>
                  <CapabilityBadges capabilities={worker.capabilities} />
                </Td>
                <Td wrap>{worker.capabilityDiagnostics ? <TextPreview maxLines={3} text={worker.capabilityDiagnostics} /> : "—"}</Td>
                <Td>
                  <MacosDrainCell drain={worker.macosDrain} />
                </Td>
                <Td>{worker.threads || "—"}</Td>
                <Td mono>{worker.lastHeartbeatAt || "—"}</Td>
                <Td>
                  <StaleBadge stale={worker.stale} />
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
      <SectionLabel>{i18n.t("chat:all_process_count", { count: card.processes.length })}</SectionLabel>
      {card.processes.length === 0 ? (
        <EmptyState>{i18n.t("chat:ops_no_processes_found_59c7bd")}</EmptyState>
      ) : (
        <Table responsive>
          <THead
            columns={[
              i18n.t("chat:ops_kind_e00ac2"),
              i18n.t("chat:ops_host_3960ec"),
              "Pid",
              i18n.t("chat:ops_capabilities_ca09c5"),
              i18n.t("chat:ops_diagnostics_3af227"),
              i18n.t("chat:ops_mac_update_f41288"),
              i18n.t("chat:ops_heartbeat_eb4d41"),
              i18n.t("chat:ops_status_bae7d5")
            ]}
          />
          <TBody>
            {card.processes.map((process) => (
              <tr key={process.key}>
                <Td>{process.kind || "—"}</Td>
                <Td mono>
                  <InternalLink href="/admin/queue/workers">{process.hostname}</InternalLink>
                </Td>
                <Td mono>{process.pid || "—"}</Td>
                <Td>
                  <CapabilityBadges capabilities={process.capabilities} />
                </Td>
                <Td wrap>{process.capabilityDiagnostics ? <TextPreview maxLines={3} text={process.capabilityDiagnostics} /> : "—"}</Td>
                <Td>
                  <MacosDrainCell drain={process.macosDrain} />
                </Td>
                <Td mono>{process.lastHeartbeatAt || "—"}</Td>
                <Td>
                  <StaleBadge stale={process.stale} />
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
      <Metadata
        values={[
          [i18n.t("chat:ops_sort_adc4e9"), card.sort],
          [i18n.t("chat:ops_worker_health_1ad1ef"), card.workerHealth]
        ]}
      />
    </CardShell>
  )
}

const adminQueueDetailToolCard: ToolCardRenderer = {
  toolName: "admin_queue_detail",
  collapsedSummary,
  renderExpanded
}

export default adminQueueDetailToolCard
