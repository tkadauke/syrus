import { readInitialBootstrap } from "@app/api/bootstrap"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { formatBytesLarge, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"
import { CardShell, displayValue, EmptyState, Row, StatePill } from "../toolCardUi"

type InstanceRow = {
  key: string
  id: string | null
  hostname: string
  role: string | null
  version: string | null
  startedAt: string | null
  lastHeartbeatAt: string | null
  disk: {
    level: string | null
    usedPercent: number | null
    hostname: string | null
    path: string | null
    availableBytes: number | null
    totalBytes: number | null
    observedAt: string | null
  } | null
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseInstanceRow(value: unknown, index: number): InstanceRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null
  const usage = isPlainObject(value.data_root_usage) ? value.data_root_usage : null

  return {
    key: `${displayValue(value.id) ?? hostname}-${index}`,
    id: displayValue(value.id),
    hostname,
    role: displayValue(value.role),
    version: displayValue(value.version),
    startedAt: displayValue(value.started_at),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    disk: usage
      ? {
          level: displayValue(usage.level),
          usedPercent: finiteNumber(usage.used_percent),
          hostname: displayValue(usage.hostname),
          path: displayValue(usage.path),
          availableBytes: finiteNumber(usage.available_bytes),
          totalBytes: finiteNumber(usage.total_bytes),
          observedAt: displayValue(usage.observed_at)
        }
      : null
  }
}

type VersionCard = {
  requestHandlerHostname: string | null
  requestHandlerRole: string | null
  requestHandlerVersion: string | null
  instances: InstanceRow[]
}

function parseVersionCard(context: ToolCardContext): VersionCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.request_handler) || !Array.isArray(parsed.instances)) return null
  return {
    requestHandlerHostname: displayValue(parsed.request_handler.hostname),
    requestHandlerRole: displayValue(parsed.request_handler.role),
    requestHandlerVersion: displayValue(parsed.request_handler.version),
    instances: parsed.instances.flatMap((instance, index) => {
      const row = parseInstanceRow(instance, index)
      return row ? [row] : []
    })
  }
}

function commitUrl(version: string | null): string | null {
  if (!version) return null
  const configuredUrl = readInitialBootstrap()?.app?.revision_url
  if (!configuredUrl) return null
  const repositoryUrl = configuredUrl.match(/^(https:\/\/github\.com\/[^/]+\/[^/]+)\/commit\/[^/]+$/)?.[1]
  return repositoryUrl ? `${repositoryUrl}/commit/${encodeURIComponent(version)}` : null
}

function CopyableValue({ value, href }: { value: string | null; href?: string | null }) {
  if (!value) return <span className="font-mono text-xs">—</span>
  if (!href) return <CopyableSlug className="whitespace-normal" slug={value} />
  return (
    <span className="inline-flex min-w-0 items-center gap-1">
      <a className="break-all font-mono text-xs font-medium text-brand hover:underline" href={href} rel="noreferrer" target="_blank">
        {value}
      </a>
      <CopyableSlug className="[&>span]:hidden" slug={value} />
    </span>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseVersionCard(context)
  if (!card) return null
  const versions = new Set(card.instances.map((instance) => instance.version).filter(Boolean))
  const mixed = versions.size > 1 ? " (mixed versions -- deploy in progress?)" : ""
  return `${card.instances.length} live instance${card.instances.length === 1 ? "" : "s"}${mixed}`
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <CardShell>
        <EmptyState>Unable to load instance versions.</EmptyState>
      </CardShell>
    )
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
            <CopyableValue href={commitUrl(card.requestHandlerVersion)} value={card.requestHandlerVersion} />
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
              const handler = instance.hostname === card.requestHandlerHostname && (!card.requestHandlerRole || instance.role === card.requestHandlerRole)
              return (
                <tr key={instance.key}>
                  <Td mono>{instance.id ?? "—"}</Td>
                  <Td wrap>
                    <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                      <CopyableSlug slug={instance.hostname} />
                      {handler ? <StatePill state="request handler" tone="info" /> : null}
                    </span>
                  </Td>
                  <Td>{instance.role ?? "—"}</Td>
                  <Td wrap>
                    <CopyableValue href={commitUrl(instance.version)} value={instance.version} />
                  </Td>
                  <Td mono>{instance.startedAt ?? "—"}</Td>
                  <Td mono>{instance.lastHeartbeatAt ?? "—"}</Td>
                  <Td wrap>
                    {instance.disk ? (
                      <div className="space-y-0.5">
                        <div className="flex flex-wrap items-center gap-1">
                          {instance.disk.level ? <HealthPill level={parseHealthLevel(instance.disk.level)} /> : null}
                          {instance.disk.usedPercent != null ? <span className="font-mono">{instance.disk.usedPercent.toFixed(1)}%</span> : null}
                        </div>
                        {instance.disk.hostname ? <CopyableValue value={instance.disk.hostname} /> : null}
                        {instance.disk.path ? <div className="break-all font-mono">{instance.disk.path}</div> : null}
                        {instance.disk.availableBytes != null || instance.disk.totalBytes != null ? (
                          <div>
                            {formatBytesLarge(instance.disk.availableBytes)} available / {formatBytesLarge(instance.disk.totalBytes)} total
                          </div>
                        ) : null}
                        {instance.disk.observedAt ? <div className="font-mono text-text-muted">Observed {instance.disk.observedAt}</div> : null}
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

const adminVersionToolCard: ToolCardRenderer = { toolName: "admin_version", collapsedSummary, renderExpanded }

export default adminVersionToolCard
