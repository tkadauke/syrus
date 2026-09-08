import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { HealthPill, parseWorkerHealthCounts, type WorkerHealthCounts } from "../adminToolCard"

// Core-owned tool card for admin_overview (EPIC-293 / JOB-4227). The tool
// echoes a handful of top-level rollup counts plus a much larger nested
// `overview` object (rate limits, provider circuits, worker health, ...);
// this card surfaces the counts and the notable red/yellow entries from
// that nested object (open provider circuits, blocked GitHub API users,
// unhealthy workers) and leaves the rest to the "Raw details" disclosure.
type QueueSummary = { active: number | null; pending: number | null; failed: number | null }

type ProviderCircuitRow = { key: string; provider: string; reason: string | null; retryAfter: string | null; model: string | null }

type BlockedUserRow = { key: string; email: string | null; reason: string | null }

type OverviewCard = {
  totalUsers: number | null
  activeRepositories: number | null
  openJobs: number | null
  runningWorkflows: number | null
  queueSummary: QueueSummary
  lowRateLimitCount: number
  blockedUsers: BlockedUserRow[]
  openProviderCircuits: ProviderCircuitRow[]
  workerHealth: WorkerHealthCounts | null
}

function parseQueueSummary(value: unknown): QueueSummary {
  if (!isPlainObject(value)) return { active: null, pending: null, failed: null }
  return { active: numberValue(value.active), pending: numberValue(value.pending), failed: numberValue(value.failed) }
}

function parseProviderCircuit(value: unknown, index: number): ProviderCircuitRow | null {
  if (!isPlainObject(value)) return null
  if (value.open !== true) return null
  const provider = displayValue(value.provider)
  if (!provider) return null

  return {
    key: `${provider}-${index}`,
    provider,
    reason: displayValue(value.reason),
    retryAfter: displayValue(value.retry_after),
    model: displayValue(value.model)
  }
}

function parseBlockedUser(value: unknown, index: number): BlockedUserRow | null {
  if (!isPlainObject(value)) return null
  return {
    key: `${displayValue(value.id) ?? index}`,
    email: displayValue(value.email),
    reason: displayValue(value.reason)
  }
}

function parseOverview(context: ToolCardContext): OverviewCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  if (typeof parsed.total_users !== "number" && !isPlainObject(parsed.queue_summary)) return null

  const overview = isPlainObject(parsed.overview) ? parsed.overview : {}
  const rateLimits = Array.isArray(overview.github_rate_limits) ? overview.github_rate_limits : []
  const blockedUsers = Array.isArray(overview.github_api_blocked_users)
    ? overview.github_api_blocked_users.flatMap((user, index) => { const row = parseBlockedUser(user, index); return row ? [row] : [] })
    : []
  const openProviderCircuits = Array.isArray(overview.provider_circuits)
    ? overview.provider_circuits.flatMap((circuit, index) => { const row = parseProviderCircuit(circuit, index); return row ? [row] : [] })
    : []

  return {
    totalUsers: numberValue(parsed.total_users),
    activeRepositories: numberValue(parsed.active_repositories),
    openJobs: numberValue(parsed.open_jobs),
    runningWorkflows: numberValue(parsed.running_workflows),
    queueSummary: parseQueueSummary(parsed.queue_summary),
    lowRateLimitCount: rateLimits.length,
    blockedUsers,
    openProviderCircuits,
    workerHealth: parseWorkerHealthCounts(overview.worker_health)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseOverview(context)
  if (!card) return null

  const parts = [
    card.openJobs != null ? `${card.openJobs} open Job${card.openJobs === 1 ? "" : "s"}` : null,
    card.runningWorkflows != null ? `${card.runningWorkflows} running` : null,
    card.queueSummary.failed != null ? `${card.queueSummary.failed} failed (24h)` : null
  ].filter(Boolean)

  return parts.length > 0 ? parts.join(", ") : "Admin overview"
}

function StatTile({ label, value }: { label: string; value: number | null }) {
  return (
    <div className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="font-mono text-sm text-gray-900 dark:text-gray-100">{value ?? "—"}</div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseOverview(context)
  if (!card) return null

  const hasNotable = card.openProviderCircuits.length > 0 || card.blockedUsers.length > 0 || card.lowRateLimitCount > 0 || (card.workerHealth && card.workerHealth.worst !== "ok")

  return (
    <CardShell>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <StatTile label="Users" value={card.totalUsers} />
        <StatTile label="Active repos" value={card.activeRepositories} />
        <StatTile label="Open Jobs" value={card.openJobs} />
        <StatTile label="Running Workflows" value={card.runningWorkflows} />
      </div>
      <dl className="grid gap-1 sm:grid-cols-3">
        <Row label="Queue active" value={String(card.queueSummary.active ?? "—")} />
        <Row label="Queue pending" value={String(card.queueSummary.pending ?? "—")} />
        <Row label="Queue failed (24h)" value={String(card.queueSummary.failed ?? "—")} />
      </dl>
      {hasNotable ? (
        <div className="space-y-2">
          <SectionLabel>Notable</SectionLabel>
          {card.workerHealth && card.workerHealth.worst !== "ok" ? (
            <div className="flex items-center gap-2">
              <HealthPill level={card.workerHealth.worst} />
              <span className="text-gray-600 dark:text-gray-300">
                {card.workerHealth.byLevel.critical + card.workerHealth.byLevel.warning} of {card.workerHealth.total} workers need attention
              </span>
            </div>
          ) : null}
          {card.openProviderCircuits.length > 0 ? (
            <div>
              <div className="text-2xs text-gray-500 dark:text-gray-400">Open provider circuits</div>
              <ul className="mt-1 space-y-1">
                {card.openProviderCircuits.map((circuit) => (
                  <li className="flex flex-wrap items-center gap-2" key={circuit.key}>
                    <StatePill state="open" tone="failure" />
                    <span className="font-mono text-gray-700 dark:text-gray-300">{circuit.provider}</span>
                    {circuit.model ? <Badge>{circuit.model}</Badge> : null}
                    {circuit.reason ? <span className="text-gray-500 dark:text-gray-400">{circuit.reason}</span> : null}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {card.blockedUsers.length > 0 ? (
            <div>
              <div className="text-2xs text-gray-500 dark:text-gray-400">GitHub API blocked users ({card.blockedUsers.length})</div>
              <ul className="mt-1 space-y-1">
                {card.blockedUsers.map((user) => (
                  <li className="flex flex-wrap items-center gap-2" key={user.key}>
                    <span className="font-mono text-gray-700 dark:text-gray-300">{user.email ?? "—"}</span>
                    {user.reason ? <span className="text-gray-500 dark:text-gray-400">{user.reason}</span> : null}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {card.lowRateLimitCount > 0 ? (
            <div className="text-gray-600 dark:text-gray-300">{card.lowRateLimitCount} user{card.lowRateLimitCount === 1 ? "" : "s"} under 10% GitHub rate limit</div>
          ) : null}
        </div>
      ) : null}
    </CardShell>
  )
}

const adminOverviewToolCard: ToolCardRenderer = {
  toolName: "admin_overview",
  collapsedSummary,
  renderExpanded
}

export default adminOverviewToolCard
