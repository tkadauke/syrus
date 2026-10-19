import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { redactToolCardValue } from "@app/toolCardSecurity"
import i18n from "../../../i18n"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { formatBytesLarge, formatPercent, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"

type Obj = Record<string, unknown>
type TranslateOptions = Record<string, string | number>
const t = (key: string, options?: TranslateOptions) => i18n.t(`admin:tool_cards.admin_overview.${key}`, options)
const obj = (v: unknown): Obj | null => (isPlainObject(v) ? v : null)
const list = (v: unknown): Obj[] => (Array.isArray(v) ? v.filter(isPlainObject) : [])
const words = (v: unknown) => (Array.isArray(v) ? v.flatMap((x) => (displayValue(x) ? [displayValue(x)!] : [])) : [])
const countMap = (v: unknown) => Object.fromEntries(Object.entries(obj(v) ?? {}).flatMap(([k, n]) => (numberValue(n) == null ? [] : [[k, numberValue(n)!]])))

function DetailPreview({ label, value }: { label: string; value: unknown }) {
  return <TextPreview maxLines={5} text={JSON.stringify(redactToolCardValue(value), null, 2)} title={label} />
}

function degradedDisk(disk: Obj) {
  return ["warning", "critical"].includes(displayValue(disk.level)?.toLowerCase() ?? "")
}

function hasAdmissionPressure(admission: Obj | null) {
  return admission ? ["delayed_work", "low_confidence_profiles", "admission_overrides"].some((key) => list(admission[key]).length > 0) : false
}

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
    workerHealth: health,
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
  if (context.resultError) return t("summary_failed")
  const card = parse(context)
  if (!card) return null
  const jobs = numberValue(card.root.open_jobs),
    workflows = numberValue(card.root.running_workflows)
  return (
    [
      jobs == null ? null : t("summary_open_jobs", { count: jobs }),
      workflows == null ? null : t("summary_running", { count: workflows }),
      card.queue.failed == null ? null : t("summary_failed_runs", { count: card.queue.failed })
    ]
      .filter(Boolean)
      .join(", ") || t("summary")
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
          <span className="text-xs text-text-muted">{t("none")}</span>
        )}
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <EmptyState>{context.resultBody || t("failed")}</EmptyState>
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
  const captureRate = numberValue(card.capture?.rate)
  const allHealthy =
    !card.circuits.length &&
    !card.rates.length &&
    !card.blocked.length &&
    !unhealthy.length &&
    (card.queue.failed ?? 0) === 0 &&
    (numberValue(card.stalled?.total) ?? 0) === 0 &&
    (captureRate == null || captureRate >= 0.95) &&
    card.storage?.available === true &&
    !card.disks.some(degradedDisk) &&
    card.workerSummary?.unreachable !== true &&
    (numberValue(card.workerSummary?.stale) ?? 0) === 0 &&
    card.recurring?.unreachable !== true &&
    list(card.recurring?.overdue).length === 0 &&
    !hasAdmissionPressure(card.admission)

  return (
    <CardShell>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label={t("users")} value={numberValue(card.root.total_users)} href="/admin/users" />
        <Stat label={t("active_repositories")} value={numberValue(card.root.active_repositories)} />
        <Stat label={t("open_jobs")} value={numberValue(card.root.open_jobs)} href="/dashboard/jobs" />
        <Stat label={t("running_workflows")} value={numberValue(card.root.running_workflows)} href="/admin/activity" />
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label={t("active_runs")} value={card.queue.active} href="/admin/queue/active" />
        <Stat label={t("pending_runs")} value={card.queue.pending} href="/admin/queue/pending" />
        <Stat label={t("failed_runs")} value={card.queue.failed} href="/admin/queue/failed" />
        <Stat
          label={t("workers")}
          value={card.workerSummary?.unreachable === true ? t("unreachable") : (numberValue(card.workerSummary?.total) ?? currentWorkers.length)}
          href="/admin/queue/workers"
        />
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        <TriggerCounts label={t("active_by_trigger")} counts={card.activeByTrigger} />
        <TriggerCounts label={t("failures_by_trigger")} counts={card.failedByTrigger} />
      </div>
      {allHealthy ? <EmptyState>{t("all_healthy")}</EmptyState> : null}

      {card.circuits.length ? (
        <div>
          <SectionLabel>{t("open_provider_circuits")}</SectionLabel>
          <div className="mt-1 space-y-2">
            {card.circuits.map((circuit, index) => {
              const provider = displayValue(circuit.provider) ?? t("unknown"),
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
                      <InternalLink href="/admin">{t("admin_overview")}</InternalLink>
                    </span>
                  </div>
                  {displayValue(circuit.reason) ? <MarkdownPreview maxLines={3} text={displayValue(circuit.reason)!} title={t("reason")} /> : null}
                  <dl className="mt-1 grid grid-cols-2 gap-1 sm:grid-cols-4">
                    <Row label={t("retry_after")} value={displayValue(circuit.retry_after) ?? "—"} />
                    <Row label={t("failures")} value={String(numberValue(circuit.failure_count) ?? "—")} />
                    <Row label={t("jobs")} value={String(numberValue(circuit.job_count) ?? "—")} />
                    <Row label={t("evidence")} value={String(evidence)} />
                  </dl>
                  {displayValue(circuit.signature) ? <TextPreview maxLines={2} text={displayValue(circuit.signature)!} title={t("signature")} /> : null}
                  {circuit.usage_limit === true ? (
                    <Row label={t("usage_limit")} value={t("exhausted")} />
                  ) : usage ? (
                    <Row
                      label={t("usage_limit")}
                      value={displayValue(usage.message) ?? displayValue(usage.reason) ?? displayValue(usage.kind) ?? t("present")}
                    />
                  ) : null}
                  {evidenceRecord ? (
                    <Row
                      label={t("evidence")}
                      value={
                        [
                          displayValue(evidenceRecord.source),
                          displayValue(evidenceRecord.status),
                          displayValue(evidenceRecord.model),
                          displayValue(evidenceRecord.observed_at),
                          numberValue(evidenceRecord.run_id) == null ? null : `RUN-${numberValue(evidenceRecord.run_id)}`
                        ]
                          .filter(Boolean)
                          .join(" · ") || t("present")
                      }
                    />
                  ) : null}
                  <DetailPreview label={t("circuit_details")} value={circuit} />
                  <div className="mt-1 text-xs text-text-muted">
                    {t("inspect_with")} <code>inspect_provider_circuit</code>.
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      ) : null}

      <Disclosure label={t("github_diagnostics")}>
        {card.rates.length ? (
          <>
            <SectionLabel>{t("low_rate_limits")}</SectionLabel>
            <Table responsive>
              <THead columns={[t("user"), t("remaining"), t("limit"), t("resource")]} />
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
          <EmptyState>{t("no_low_rate_limits")}</EmptyState>
        )}
        {card.blocked.length ? (
          <>
            <SectionLabel>{t("blocked_users")}</SectionLabel>
            <Table responsive>
              <THead columns={[t("user"), t("blocked"), t("reason"), t("rate_limit"), t("reset"), t("observed")]} />
              <TBody>
                {card.blocked.map((user, index) => {
                  const rate = obj(user.rate_limit) ?? {},
                    id = numberValue(user.id)
                  return (
                    <tr key={`${id ?? index}-${index}`}>
                      <Td primary>
                        {id ? (
                          <InternalLink href={`/admin/users/${id}`}>{displayValue(user.email) ?? t("user_id", { id })}</InternalLink>
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
          <EmptyState>{t("no_blocked_users")}</EmptyState>
        )}
      </Disclosure>

      <Disclosure label={t("worker_health")}>
        <div className="flex flex-wrap items-center gap-2 text-xs">
          <InternalLink href="/admin/queue/workers">{t("open_worker_detail")}</InternalLink>
          <span className="text-text-muted">{t("unhealthy_workers", { unhealthy: unhealthy.length, total: currentWorkers.length })}</span>
        </div>
        {currentWorkers.length ? (
          <Table responsive>
            <THead columns={[t("host"), t("role"), t("health"), t("reasons"), t("heartbeat"), t("details")]} />
            <TBody>
              {currentWorkers.map((worker) => (
                <tr key={worker.key}>
                  <Td mono primary>
                    <InternalLink href="/admin/queue/workers">{worker.hostname ?? t("unknown")}</InternalLink>
                  </Td>
                  <Td>{worker.role ?? "—"}</Td>
                  <Td>
                    <HealthPill level={worker.level} />
                    {worker.stale ? ` ${t("stale")}` : ""}
                  </Td>
                  <Td wrap>{worker.reasons.join("; ") || "—"}</Td>
                  <Td mono>{worker.heartbeat ?? "—"}</Td>
                  <Td wrap>
                    <DetailPreview label={t("worker_details")} value={card.workers.find((item) => displayValue(item.hostname) === worker.hostname) ?? {}} />
                  </Td>
                </tr>
              ))}
            </TBody>
          </Table>
        ) : (
          <EmptyState>{t("no_worker_health")}</EmptyState>
        )}
        <DetailPreview label={t("worker_health_details")} value={card.workerHealth} />
      </Disclosure>

      <Disclosure label={t("system_diagnostics")}>
        <dl className="grid gap-2 sm:grid-cols-2 lg:grid-cols-4">
          <Row
            label={t("agent_session_capture")}
            value={
              captureRate == null
                ? `${numberValue(card.capture?.captured) ?? 0} / ${numberValue(card.capture?.total) ?? 0}`
                : `${formatPercent(captureRate * 100)} (${numberValue(card.capture?.captured) ?? 0} / ${numberValue(card.capture?.total) ?? 0})`
            }
          />
          <Row
            label={t("active_storage")}
            value={
              card.storage?.available === true
                ? `${t("available")} · ${displayValue(card.storage.service) ?? t("service_unknown")}`
                : `${t("unavailable")} · ${displayValue(card.storage?.message) ?? displayValue(card.storage?.error_class) ?? t("unknown_error")}`
            }
          />
          <Row label={t("stalled_classifier_jobs")} value={String(numberValue(card.stalled?.total) ?? 0)} />
          <Row label={t("recurring_tasks")} value={card.recurring?.unreachable === true ? t("unreachable") : String(numberValue(card.recurring?.count) ?? 0)} />
        </dl>
        {displayValue(card.stalled?.oldest_job_path) ? (
          <div className="mt-1 text-xs">
            <InternalLink href={displayValue(card.stalled?.oldest_job_path)!}>{t("open_oldest_classifier_job")}</InternalLink>
          </div>
        ) : null}
        {list(card.recurring?.overdue).length ? (
          <div className="mt-1 text-xs text-warning-text">
            {t("overdue")}:{" "}
            {list(card.recurring?.overdue)
              .map((item) => displayValue(item.key))
              .filter(Boolean)
              .join(", ")}
          </div>
        ) : null}
        {card.disks.length ? (
          <Table responsive>
            <THead
              columns={[
                t("host"),
                t("path"),
                t("filesystem"),
                t("mounted_on"),
                t("used"),
                t("used_bytes"),
                t("available"),
                t("total"),
                t("level"),
                t("observed"),
                t("details")
              ]}
            />
            <TBody>
              {card.disks.map((disk, index) => (
                <tr key={`${displayValue(disk.hostname) ?? "local"}-${index}`}>
                  <Td mono primary>
                    {displayValue(disk.hostname) ?? t("local")}
                  </Td>
                  <Td mono wrap>
                    {displayValue(disk.path) ?? "—"}
                  </Td>
                  <Td mono>{displayValue(disk.filesystem) ?? "—"}</Td>
                  <Td mono>{displayValue(disk.mounted_on) ?? "—"}</Td>
                  <Td mono>{formatPercent(numberValue(disk.used_percent))}</Td>
                  <Td mono>{formatBytesLarge(numberValue(disk.used_bytes))}</Td>
                  <Td mono>{formatBytesLarge(numberValue(disk.available_bytes))}</Td>
                  <Td mono>{formatBytesLarge(numberValue(disk.total_bytes))}</Td>
                  <Td>{displayValue(disk.level) ? <StatePill state={displayValue(disk.level)!} /> : "—"}</Td>
                  <Td mono>{displayValue(disk.observed_at) ?? "—"}</Td>
                  <Td wrap>
                    <DetailPreview label={t("disk_details")} value={disk} />
                  </Td>
                </tr>
              ))}
            </TBody>
          </Table>
        ) : (
          <EmptyState>{t("no_disk_usage")}</EmptyState>
        )}
        <DetailPreview
          label={t("system_details")}
          value={{
            capture: card.capture,
            active_storage: card.storage,
            stalled_classifier_jobs: card.stalled,
            workers: card.workerSummary,
            recurring: card.recurring
          }}
        />
      </Disclosure>

      <Disclosure label={t("resource_admission")}>
        <div className="mb-2 text-xs">
          <InternalLink href="/admin/resource_admission">{t("open_resource_admission")}</InternalLink>
        </div>
        {card.admission ? (
          <div className="space-y-2">
            <dl className="grid gap-2 sm:grid-cols-3">
              <Row label={t("generated_at")} value={displayValue(card.admission.generated_at) ?? "—"} />
              <Row label={t("recent_window")} value={String(numberValue(obj(card.admission.windows)?.recent_hours) ?? "—")} />
              <Row label={t("delayed_window")} value={String(numberValue(obj(card.admission.windows)?.delayed_hours) ?? "—")} />
            </dl>
            {["delayed_work", "active_consumers", "recent_top_consumers", "low_confidence_profiles", "admission_overrides"].map((key) => (
              <div key={key}>
                <SectionLabel>{t(key)}</SectionLabel>
                {list(card.admission?.[key]).length ? (
                  list(card.admission?.[key]).map((item, index) => (
                    <div className="mt-1 rounded border border-border bg-surface-subtle p-2" key={`${key}-${index}`}>
                      <div className="flex flex-wrap gap-2 text-xs">
                        {displayValue(obj(item.job)?.path) ? (
                          <InternalLink href={displayValue(obj(item.job)?.path)!}>{displayValue(obj(item.job)?.slug) ?? t("job")}</InternalLink>
                        ) : null}
                        {displayValue(item.workflow_path) ? (
                          <InternalLink href={displayValue(item.workflow_path)!}>
                            {numberValue(item.workflow_id) == null ? t("workflow") : `WF-${numberValue(item.workflow_id)}`}
                          </InternalLink>
                        ) : null}
                      </div>
                      <DetailPreview label={t("item_details")} value={item} />
                    </div>
                  ))
                ) : (
                  <EmptyState>{t("none")}</EmptyState>
                )}
              </div>
            ))}
            <DetailPreview label={t("resource_admission_details")} value={card.admission} />
          </div>
        ) : (
          <EmptyState>{t("resource_admission_missing")}</EmptyState>
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
            filesystem: "/dev/pvc",
            mounted_on: "/syrus-home",
            used_percent: 91,
            used_bytes: 91000000,
            available_bytes: 9000000,
            total_bytes: 100000000,
            level: "warning",
            observed_at: "2026-10-19T00:00:00Z"
          }
        ],
        workers: { total: 2, stale: 1 },
        recurring: { count: 7, overdue: [{ key: "poll_repositories" }] },
        resource_admission: {
          generated_at: "2026-10-19T00:00:00Z",
          windows: { recent_hours: 24, delayed_hours: 48 },
          delayed_work: [{ workflow_id: 2, workflow_path: "/jobs/57?tab=workflows#workflow-2", reason: "host pressure" }],
          active_consumers: [{ run_id: 3, job: { slug: "JOB-57", path: "/jobs/57" }, pressure: { cpu_pressure: 0.8 } }],
          recent_top_consumers: [],
          low_confidence_profiles: [{ id: 4 }],
          admission_overrides: []
        },
        worker_health: {
          current: [
            {
              hostname: "worker-1",
              role: "runs",
              version: "abc123",
              capabilities: { os: ["linux"] },
              sample: { cpu_used_percent: 92 },
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
