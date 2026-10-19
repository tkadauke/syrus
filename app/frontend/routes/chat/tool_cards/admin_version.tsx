import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { CardShell, displayValue, EmptyState, Row, StatePill } from "../toolCardUi"
import { formatBytesLarge, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"

function CopyableValue({ value, href }: { value: string | null; href?: string | null }) {
  if (!value) return <span className="font-mono text-xs">—</span>
  return (
    <span className="inline-flex min-w-0 items-center gap-1">
      {href ? (
        <a className="break-all font-mono text-xs font-medium text-brand hover:underline" href={href} rel="noreferrer" target="_blank">
          {value}
        </a>
      ) : (
        <span className="break-all font-mono text-xs">{value}</span>
      )}
      <CopyableSlug className="[&>span]:hidden" slug={value} />
    </span>
  )
}

// Core-owned tool card for admin_version (the tool-card work). Renders the
// request-handling instance's own identity, the live instance roster
// (rolling deploy visibility -- old and new SHAs both show up mid-rollout).
type InstanceRow = {
  key: string
  id: string | null
  hostname: string
  role: string | null
  version: string | null
  startedAt: string | null
  lastHeartbeatAt: string | null
  diskLevel: string | null
  hasDiskUsage: boolean
  diskUsedPercent: number | null
  diskHostname: string | null
  diskPath: string | null
  diskAvailableBytes: number | null
  diskTotalBytes: number | null
  diskObservedAt: string | null
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseInstanceRow(value: unknown, index: number): InstanceRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  const diskUsage = isPlainObject(value.data_root_usage) ? value.data_root_usage : null

  return {
    key: `${displayValue(value.id) ?? hostname}-${index}`,
    id: displayValue(value.id),
    hostname,
    role: displayValue(value.role),
    version: displayValue(value.version),
    startedAt: displayValue(value.started_at),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    diskLevel: diskUsage ? displayValue(diskUsage.level) : null,
    hasDiskUsage: diskUsage != null,
    diskUsedPercent: diskUsage ? finiteNumber(diskUsage.used_percent) : null,
    diskHostname: diskUsage ? displayValue(diskUsage.hostname) : null,
    diskPath: diskUsage ? displayValue(diskUsage.path) : null,
    diskAvailableBytes: diskUsage ? finiteNumber(diskUsage.available_bytes) : null,
    diskTotalBytes: diskUsage ? finiteNumber(diskUsage.total_bytes) : null,
    diskObservedAt: diskUsage ? displayValue(diskUsage.observed_at) : null
  }
}

type VersionCard = {
  repositoryUrl: string | null
  requestHandlerHostname: string | null
  requestHandlerRole: string | null
  requestHandlerVersion: string | null
  instances: InstanceRow[]
}

function parseVersionCard(context: ToolCardContext): VersionCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.request_handler) || !Array.isArray(parsed.instances)) return null

  return {
    repositoryUrl: displayValue(parsed.repository_url),
    requestHandlerHostname: displayValue(parsed.request_handler.hostname),
    requestHandlerRole: displayValue(parsed.request_handler.role),
    requestHandlerVersion: displayValue(parsed.request_handler.version),
    instances: parsed.instances.flatMap((instance, index) => {
      const row = parseInstanceRow(instance, index)
      return row ? [row] : []
    })
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
  if (context.resultError) {
    return (
      <CardShell>
        <EmptyState>Unable to load instance versions.</EmptyState>
      </CardShell>
    )
  }
  const card = parseVersionCard(context)
  if (!card) return null

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-3">
        <div className="min-w-0">
          <dt className="text-2xs font-medium uppercase tracking-wide text-text-muted">Handling host</dt>
          <dd>
            <CopyableValue value={card.requestHandlerHostname} />
          </dd>
        </div>
        <Row label="Role" value={card.requestHandlerRole ?? "—"} />
        <div className="min-w-0">
          <dt className="text-2xs font-medium uppercase tracking-wide text-text-muted">Version</dt>
          <dd>
            <CopyableValue
              href={card.repositoryUrl && card.requestHandlerVersion ? `${card.repositoryUrl}/commit/${encodeURIComponent(card.requestHandlerVersion)}` : null}
              value={card.requestHandlerVersion}
            />
          </dd>
        </div>
      </dl>
      {card.instances.length === 0 ? (
        <EmptyState>No live instances found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["ID", "Host", "Role", "Version", "Started", "Heartbeat", "Disk"]} />
          <TBody>
            {card.instances.map((instance) => {
              const handlesRequest =
                instance.hostname === card.requestHandlerHostname && (!card.requestHandlerRole || instance.role === card.requestHandlerRole)
              const versionUrl = card.repositoryUrl && instance.version ? `${card.repositoryUrl}/commit/${encodeURIComponent(instance.version)}` : null
              return (
                <tr key={instance.key}>
                  <Td mono>{instance.id ?? "—"}</Td>
                  <Td wrap>
                    <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                      <CopyableSlug slug={instance.hostname} />
                      {handlesRequest ? <StatePill state="request handler" tone="info" /> : null}
                    </span>
                  </Td>
                  <Td>{instance.role || "—"}</Td>
                  <Td wrap>
                    {instance.version ? (
                      <span className="inline-flex min-w-0 items-center gap-1">
                        <CopyableValue href={versionUrl} value={instance.version} />
                      </span>
                    ) : (
                      "—"
                    )}
                  </Td>
                  <Td mono>{instance.startedAt || "—"}</Td>
                  <Td mono>{instance.lastHeartbeatAt || "—"}</Td>
                  <Td wrap>
                    {instance.hasDiskUsage ? (
                      <div className="space-y-0.5">
                        <div className="flex flex-wrap items-center gap-1">
                          {instance.diskLevel ? <HealthPill level={parseHealthLevel(instance.diskLevel)} /> : null}
                          {instance.diskUsedPercent != null ? <span className="font-mono">{instance.diskUsedPercent.toFixed(1)}%</span> : null}
                        </div>
                        {instance.diskHostname ? <CopyableValue value={instance.diskHostname} /> : null}
                        {instance.diskPath ? <div className="break-all font-mono">{instance.diskPath}</div> : null}
                        {instance.diskAvailableBytes != null || instance.diskTotalBytes != null ? (
                          <div>
                            {formatBytesLarge(instance.diskAvailableBytes)} available / {formatBytesLarge(instance.diskTotalBytes)} total
                          </div>
                        ) : null}
                        {instance.diskObservedAt ? <div className="font-mono text-text-muted">Observed {instance.diskObservedAt}</div> : null}
                      </div>
                    ) : (
                      "—"
                    )}
                  </Td>
                </tr>
              )
            })}
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
