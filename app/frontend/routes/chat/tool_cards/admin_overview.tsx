import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { formatBytesLarge, formatPercent, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"

type Obj = Record<string, unknown>
const obj = (v: unknown): Obj | null => (isPlainObject(v) ? v : null)
const list = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isPlainObject) : [])
const words = (v: unknown) => (Array.isArray(v) ? v.flatMap((x) => (displayValue(x) ? [displayValue(x)!] : [])) : [])
const countMap = (v: unknown) => Object.fromEntries(Object.entries(obj(v) ?? {}).flatMap(([k, n]) => (numberValue(n) == null ? [] : [[k, numberValue(n)!]])))

function parse(context: ToolCardContext) {
  const root = obj(context.parsedResult),
    overview = obj(root?.overview)
  if (!root || !overview) return null
  const active = obj(overview.active_runs) ?? {},
    queued = obj(overview.queued_runs) ?? {},
    failed = obj(overview.recent_failures_24h) ?? {}
  const health = obj(overview.worker_health) ?? {},
    queue = obj(root.queue_summary) ?? {}
  return {
    root,
    overview,
    queue: {
      active: numberValue(active.total) ?? numberValue(queue.active),
      pending: numberValue(queued.total) ?? numberValue(queue.pending),
      failed: numberValue(failed.total) ?? numberValue(queue.failed)
    },
    activeByTrigger: countMap(active.by_trigger),
    failedByTrigger: countMap(failed.by_trigger),
    rates: list(overview.github_rate_limits),
    blocked: list(overview.github_api_blocked_users),
    circuits: list(overview.provider_circuits),
    workers: list(health.current),
    disks: [...(obj(overview.data_root_disk_usage) ? [obj(overview.data_root_disk_usage)!] : []), ...list(overview.worker_data_root_usages)],
    capture: obj(overview.agent_session_capture_rate),
    storage: obj(overview.active_storage),
    stalled: obj(overview.stalled_classifier_jobs),
    workerSummary: obj(overview.workers),
    recurring: obj(overview.recurring),
    admission: obj(overview.resource_admission)
  }
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return "Admin overview failed"
  const card = parse(context)
  if (!card) return null
  const jobs = numberValue(card.root.open_jobs),
    workflows = numberValue(card.root.running_workflows)
  return (
    [
      jobs == null ? null : `${jobs} open Job${jobs === 1 ? "" : "s"}`,
      workflows == null ? null : `${workflows} running`,
      card.queue.failed == null ? null : `${card.queue.failed} failed (24h)`
    ]
      .filter(Boolean)
      .join(", ") || "Admin overview"
  )
}

function Stat({ label, value, href }: { label: string; value: string | number | null; href?: string }) {
  const body = (
    <>
      <div className="text-2xs font-semibold uppercase text-text-muted">{label}</div>
      <div className="font-mono text-sm text-text-primary">{value ?? "—"}</div>
    </>
  )
  return (
    <div className="rounded border border-border bg-surface px-2 py-1">
      {href ? (
        <a className="block hover:underline" href={href}>
          {body}
        </a>
      ) : (
        body
      )}
    </div>
  )
}

function TriggerCounts({ label, counts }: { label: string; counts: Record<string, number> }) {
  const entries = Object.entries(counts)
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-1">
        {entries.length ? (
          entries.map(([key, value]) => (
            <Badge key={key}>
              {key}: {value}
            </Badge>
          ))
        ) : (
          <span className="text-xs text-text-muted">None</span>
        )}
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <EmptyState>{context.resultBody || "Admin overview failed."}</EmptyState>
      </CardShell>
    )
  const card = parse(context)
  if (!card) return null
  const currentWorkers = card.workers.map((worker, index) => {
    const health = obj(worker.health) ?? {}
    return {
      key: `${displayValue(worker.hostname) ?? index}-${index}`,
      hostname: displayValue(worker.hostname),
      role: displayValue(worker.role),
      stale: worker.stale === true,
      level: parseHealthLevel(health.level),
      reasons: words(health.reasons),
      heartbeat: displayValue(worker.last_heartbeat_at)
    }
  })
  const unhealthy = currentWorkers.filter((worker) => worker.stale || worker.level !== "ok")
  const allHealthy = !card.circuits.length && !card.rates.length && !card.blocked.length && !unhealthy.length && (numberValue(card.stalled?.total) ?? 0) === 0
  const captureRate = numberValue(card.capture?.rate)

  return (
    <CardShell>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Users" value={numberValue(card.root.total_users)} href="/admin/users" />
        <Stat label="Active repos" value={numberValue(card.root.active_repositories)} />
        <Stat label="Open Jobs" value={numberValue(card.root.open_jobs)} href="/dashboard/jobs" />
        <Stat label="Running Workflows" value={numberValue(card.root.running_workflows)} href="/admin/activity" />
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Active Runs" value={card.queue.active} href="/admin/queue/active" />
        <Stat label="Pending Runs" value={card.queue.pending} href="/admin/queue/pending" />
        <Stat label="Failed Runs (24h)" value={card.queue.failed} href="/admin/queue/failed" />
        <Stat
          label="Workers"
          value={card.workerSummary?.unreachable === true ? "unreachable" : (numberValue(card.workerSummary?.total) ?? currentWorkers.length)}
          href="/admin/queue/workers"
        />
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        <TriggerCounts label="Active by trigger" counts={card.activeByTrigger} />
        <TriggerCounts label="Failures by trigger (24h)" counts={card.failedByTrigger} />
      </div>
      {allHealthy ? <EmptyState>All provider, GitHub, classifier, and worker health checks are healthy.</EmptyState> : null}

      {card.circuits.length ? (
        <div>
          <SectionLabel>Open provider circuits</SectionLabel>
          <div className="mt-1 space-y-2">
            {card.circuits.map((circuit, index) => {
              const provider = displayValue(circuit.provider) ?? "unknown",
                usage = obj(circuit.usage_limit) ?? obj(circuit.decision),
                evidenceRecord = obj(circuit.evidence)
              const evidence = list(circuit.evidence_records).length + list(circuit.runs).length + (evidenceRecord ? 1 : 0)
              return (
                <div className="rounded border border-danger-border bg-danger-surface p-2" key={`${provider}-${index}`}>
                  <div className="flex flex-wrap items-center gap-2">
                    <StatePill state="open" tone="failure" />
                    <span className="font-mono text-text-primary">{provider}</span>
                    {displayValue(circuit.model) ? <Badge>{displayValue(circuit.model)}</Badge> : null}
                    <span className="ml-auto text-xs">
                      <InternalLink href="/admin">Admin overview</InternalLink>
                    </span>
                  </div>
                  {displayValue(circuit.reason) ? <MarkdownPreview maxLines={3} text={displayValue(circuit.reason)!} title="Reason" /> : null}
                  <dl className="mt-1 grid grid-cols-2 gap-1 sm:grid-cols-4">
                    <Row label="Retry after" value={displayValue(circuit.retry_after) ?? "—"} />
                    <Row label="Failures" value={String(numberValue(circuit.failure_count) ?? "—")} />
                    <Row label="Jobs" value={String(numberValue(circuit.job_count) ?? "—")} />
                    <Row label="Evidence" value={String(evidence)} />
                  </dl>
                  {displayValue(circuit.signature) ? <TextPreview maxLines={2} text={displayValue(circuit.signature)!} title="Signature" /> : null}
                  {circuit.usage_limit === true ? (
                    <Row label="Usage limit" value="exhausted" />
                  ) : usage ? (
                    <Row label="Usage limit" value={displayValue(usage.message) ?? displayValue(usage.reason) ?? displayValue(usage.kind) ?? "present"} />
                  ) : null}
                  {evidenceRecord ? (
                    <Row
                      label="Evidence"
                      value={
                        [
                          displayValue(evidenceRecord.source),
                          displayValue(evidenceRecord.status),
                          displayValue(evidenceRecord.model),
                          displayValue(evidenceRecord.observed_at),
                          numberValue(evidenceRecord.run_id) == null ? null : `RUN-${numberValue(evidenceRecord.run_id)}`
                        ]
                          .filter(Boolean)
                          .join(" · ") || "present"
                      }
                    />
                  ) : null}
                  <div className="mt-1 text-xs text-text-muted">
                    Inspect with <code>inspect_provider_circuit</code>.
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      ) : null}

      <Disclosure label="GitHub rate limits and blocked users">
        {card.rates.length ? (
          <>
            <SectionLabel>Low rate limits</SectionLabel>
            <Table responsive>
              <THead columns={["User", "Remaining", "Limit", "Resource"]} />
              <TBody>
                {card.rates.map((rate, index) => (
                  <tr key={`${displayValue(rate.email) ?? index}-${index}`}>
                    <Td primary>{displayValue(rate.email) ?? "—"}</Td>
                    <Td mono>{numberValue(rate.remaining) ?? "—"}</Td>
                    <Td mono>{numberValue(rate.limit) ?? "—"}</Td>
                    <Td>{displayValue(rate.resource) ?? "—"}</Td>
                  </tr>
                ))}
              </TBody>
            </Table>
          </>
        ) : (
          <EmptyState>No users have low GitHub rate limits.</EmptyState>
        )}
        {card.blocked.length ? (
          <>
            <SectionLabel>Blocked users</SectionLabel>
            <Table responsive>
              <THead columns={["User", "Blocked", "Reason", "Rate limit", "Reset", "Observed"]} />
              <TBody>
                {card.blocked.map((user, index) => {
                  const rate = obj(user.rate_limit) ?? {},
                    id = numberValue(user.id)
                  return (
                    <tr key={`${id ?? index}-${index}`}>
                      <Td primary>
                        {id ? (
                          <InternalLink href={`/admin/users/${id}`}>{displayValue(user.email) ?? `User ${id}`}</InternalLink>
                        ) : (
                          (displayValue(user.email) ?? "—")
                        )}
                      </Td>
                      <Td mono>{displayValue(user.blocked_at) ?? "—"}</Td>
                      <Td wrap>{displayValue(user.reason) ?? "—"}</Td>
                      <Td mono>
                        {numberValue(rate.remaining) ?? "—"} / {numberValue(rate.limit) ?? "—"} {displayValue(rate.resource) ?? ""}
                      </Td>
                      <Td mono>{displayValue(rate.reset_at) ?? "—"}</Td>
                      <Td mono>{displayValue(rate.observed_at) ?? "—"}</Td>
                    </tr>
                  )
                })}
              </TBody>
            </Table>
          </>
        ) : (
          <EmptyState>No GitHub API blocked users.</EmptyState>
        )}
      </Disclosure>

      <Disclosure label="Workers and host health">
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <InternalLink href="/admin/queue/workers">Open worker detail</InternalLink>
          <span className="text-text-muted">
            {unhealthy.length} unhealthy or stale of {currentWorkers.length} reported hosts
          </span>
        </div>
        {currentWorkers.length ? (
          <Table responsive>
            <THead columns={["Host", "Role", "Health", "Reasons", "Heartbeat"]} />
            <TBody>
              {currentWorkers.map((worker) => (
                <tr key={worker.key}>
                  <Td mono primary>
                    <InternalLink href="/admin/queue/workers">{worker.hostname ?? "unknown"}</InternalLink>
                  </Td>
                  <Td>{worker.role ?? "—"}</Td>
                  <Td>
                    <HealthPill level={worker.level} />
                    {worker.stale ? " stale" : ""}
                  </Td>
                  <Td wrap>{worker.reasons.join("; ") || "—"}</Td>
                  <Td mono>{worker.heartbeat ?? "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        ) : (
          <EmptyState>No per-host worker health was reported.</EmptyState>
        )}
      </Disclosure>

      <Disclosure label="Storage, capture, classifier, and schedules">
        <dl className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <Row
            label="Agent session capture"
            value={
              captureRate == null
                ? `${numberValue(card.capture?.captured) ?? 0} / ${numberValue(card.capture?.total) ?? 0}`
                : `${formatPercent(captureRate * 100)} (${numberValue(card.capture?.captured) ?? 0} / ${numberValue(card.capture?.total) ?? 0})`
            }
          />
          <Row
            label="Active Storage"
            value={
              card.storage?.available === true
                ? `available · ${displayValue(card.storage.service) ?? "service unknown"}`
                : `unavailable · ${displayValue(card.storage?.message) ?? displayValue(card.storage?.error_class) ?? "unknown error"}`
            }
          />
          <Row label="Stalled classifier Jobs" value={String(numberValue(card.stalled?.total) ?? 0)} />
          <Row label="Recurring tasks" value={card.recurring?.unreachable === true ? "unreachable" : String(numberValue(card.recurring?.count) ?? 0)} />
        </dl>
        {displayValue(card.stalled?.oldest_job_path) ? (
          <div className="mt-1 text-xs">
            <InternalLink href={displayValue(card.stalled?.oldest_job_path)!}>Open oldest stalled classifier Job</InternalLink>
          </div>
        ) : null}
        {list(card.recurring?.overdue).length ? (
          <div className="mt-1 text-xs text-warning-text">
            Overdue:{" "}
            {list(card.recurring?.overdue)
              .map((item) => displayValue(item.key))
              .filter(Boolean)
              .join(", ")}
          </div>
        ) : null}
        {card.disks.length ? (
          <Table responsive>
            <THead columns={["Host", "Path", "Used", "Available", "Total", "Level", "Observed"]} />
            <TBody>
              {card.disks.map((disk, index) => (
                <tr key={`${displayValue(disk.hostname) ?? "local"}-${index}`}>
                  <Td mono primary>
                    {displayValue(disk.hostname) ?? "local"}
                  </Td>
                  <Td mono wrap>
                    {displayValue(disk.path) ?? "—"}
                  </Td>
                  <Td mono>{formatPercent(numberValue(disk.used_percent))}</Td>
                  <Td mono>{formatBytesLarge(numberValue(disk.available_bytes))}</Td>
                  <Td mono>{formatBytesLarge(numberValue(disk.total_bytes))}</Td>
                  <Td>{displayValue(disk.level) ? <StatePill state={displayValue(disk.level)!} /> : "—"}</Td>
                  <Td mono>{displayValue(disk.observed_at) ?? "—"}</Td>
                </tr>
              ))}
            </TBody>
          </Table>
        ) : (
          <EmptyState>No data-root disk usage was reported.</EmptyState>
        )}
      </Disclosure>

      <Disclosure label="Resource admission">
        <div className="mb-2 text-xs">
          <InternalLink href="/admin/resource_admission">Open resource admission diagnostics</InternalLink>
        </div>
        {card.admission ? (
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-5">
            {["delayed_work", "active_consumers", "recent_top_consumers", "low_confidence_profiles", "admission_overrides"].map((key) => (
              <Stat key={key} label={key.replace(/_/g, " ")} value={list(card.admission?.[key]).length} />
            ))}
          </div>
        ) : (
          <EmptyState>Resource admission diagnostics were not returned.</EmptyState>
        )}
      </Disclosure>
    </CardShell>
  )
}

const adminOverviewToolCard: ToolCardRenderer = { toolName: "admin_overview", collapsedSummary, renderExpanded }
export default adminOverviewToolCard

const healthyOverview = {
  active_runs: { total: 1, by_trigger: { initial: 1 } },
  queued_runs: { total: 2 },
  recent_failures_24h: { total: 0, by_trigger: {} },
  github_rate_limits: [],
  github_api_blocked_users: [],
  provider_circuits: [],
  agent_session_capture_rate: { total: 8, captured: 8, rate: 1 },
  data_root_disk_usage: null,
  active_storage: { available: true, service: "local" },
  stalled_classifier_jobs: { total: 0 },
  worker_data_root_usages: [],
  workers: { total: 2, stale: 0 },
  recurring: { count: 7 },
  resource_admission: { delayed_work: [], active_consumers: [], recent_top_consumers: [], low_confidence_profiles: [], admission_overrides: [] },
  worker_health: {
    current: [
      { hostname: "worker-1", health: { level: "ok" } },
      { hostname: "worker-2", health: { level: "ok" } }
    ]
  }
}
export const examples = [
  {
    id: "healthy_fleet",
    label: "Healthy fleet, nothing notable",
    parsedResult: {
      total_users: 6,
      active_repositories: 4,
      open_jobs: 3,
      running_workflows: 1,
      queue_summary: { active: 1, pending: 2, failed: 0 },
      overview: healthyOverview
    }
  },
  {
    id: "fleet_needs_attention",
    label: "Fleet needs attention (large result)",
    description: "Provider, GitHub, storage, and worker diagnostics with a long circuit reason.",
    parsedResult: {
      total_users: 41,
      active_repositories: 19,
      open_jobs: 57,
      running_workflows: 9,
      queue_summary: { active: 9, pending: 23, failed: 4 },
      overview: {
        ...healthyOverview,
        active_runs: { total: 9, by_trigger: { initial: 5, retry: 4 } },
        recent_failures_24h: { total: 4, by_trigger: { initial: 3, retry: 1 } },
        github_rate_limits: [{ email: "alice@example.com", remaining: 60, limit: 5000, resource: "core" }],
        github_api_blocked_users: [
          {
            id: 12,
            email: "alice@example.com",
            blocked_at: "2026-10-18T20:00:00Z",
            reason: "secondary rate limit",
            rate_limit: { remaining: 0, limit: 5000, resource: "core", reset_at: "2026-10-19T01:00:00Z" }
          }
        ],
        provider_circuits: [
          {
            provider: "codex",
            model: "gpt-6",
            reason: "Repeated provider failures while starting agent sessions.\n\nRetry after the provider window resets.",
            retry_after: "2026-10-19T01:10:00Z",
            signature: "rate_limit:requests",
            failure_count: 5,
            job_count: 3,
            evidence_records: [{ id: 1 }]
          }
        ],
        agent_session_capture_rate: { total: 50, captured: 44, rate: 0.88 },
        active_storage: { available: false, error_class: "Timeout", message: "storage probe timed out" },
        stalled_classifier_jobs: { total: 2, oldest_job_path: "/jobs/stalled-job" },
        worker_data_root_usages: [
          {
            hostname: "worker-1",
            path: "/data",
            used_percent: 91,
            available_bytes: 9000000,
            total_bytes: 100000000,
            level: "warning",
            observed_at: "2026-10-19T00:00:00Z"
          }
        ],
        workers: { total: 2, stale: 1 },
        recurring: { count: 7, overdue: [{ key: "poll_repositories" }] },
        resource_admission: {
          delayed_work: [{ workflow_id: 2 }],
          active_consumers: [{ run_id: 3 }],
          recent_top_consumers: [],
          low_confidence_profiles: [{ id: 4 }],
          admission_overrides: []
        },
        worker_health: {
          current: [
            {
              hostname: "worker-1",
              role: "runs",
              stale: true,
              last_heartbeat_at: "2026-10-18T23:55:00Z",
              health: { level: "critical", reasons: ["heartbeat stale"] }
            },
            { hostname: "worker-2", role: "runs", health: { level: "ok", reasons: [] } }
          ]
        }
      }
    }
  }
]
