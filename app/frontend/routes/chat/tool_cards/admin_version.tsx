import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import type { ReactNode } from "react"
import { readInitialBootstrap } from "../../../api/bootstrap"
import { CardShell, CopyableValue, displayValue, EmptyState, Row } from "../toolCardUi"
import { formatBytesLarge, HealthPill, parseHealthLevel, Table, TBody, Td, THead } from "../adminToolCard"

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
  diskUsedPercent: number | null
  diskHostname: string | null
  diskPath: string | null
  diskAvailableBytes: number | null
  diskTotalBytes: number | null
  diskObservedAt: string | null
}

function numberField(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseInstanceRow(value: unknown, index: number): InstanceRow | null {
  if (!isPlainObject(value)) return null
  const hostname = displayValue(value.hostname)
  if (!hostname) return null

  const diskUsage = isPlainObject(value.data_root_usage) ? value.data_root_usage : null

  return {
    key: `${hostname}-${index}`,
    id: displayValue(value.id),
    hostname,
    role: displayValue(value.role),
    version: displayValue(value.version),
    startedAt: displayValue(value.started_at),
    lastHeartbeatAt: displayValue(value.last_heartbeat_at),
    diskLevel: diskUsage ? displayValue(diskUsage.level) : null,
    diskUsedPercent: diskUsage ? numberField(diskUsage.used_percent) : null,
    diskHostname: diskUsage ? displayValue(diskUsage.hostname) : null,
    diskPath: diskUsage ? displayValue(diskUsage.path) : null,
    diskAvailableBytes: diskUsage ? numberField(diskUsage.available_bytes) : null,
    diskTotalBytes: diskUsage ? numberField(diskUsage.total_bytes) : null,
    diskObservedAt: diskUsage ? displayValue(diskUsage.observed_at) : null
  }
}

function versionUrl(version: string | null): string | null {
  if (!version || version === "dev") return null
  const currentUrl = readInitialBootstrap()?.app?.revision_url
  if (!currentUrl) return null
  const commitMarker = "/commit/"
  const markerIndex = currentUrl.indexOf(commitMarker)
  return markerIndex < 0 ? null : `${currentUrl.slice(0, markerIndex)}${commitMarker}${encodeURIComponent(version)}`
}

function VersionValue({ value }: { value: string | null }) {
  return value ? <CopyableValue href={versionUrl(value)} value={value} /> : <>—</>
}

function HeaderValue({ children, label }: { children: ReactNode; label: string }) {
  return (
    <div className="min-w-0">
      <div className="text-2xs font-medium uppercase tracking-wide text-text-muted">{label}</div>
      {children}
    </div>
  )
}

function DiskUsage({ instance }: { instance: InstanceRow }) {
  if (!instance.diskLevel) return <>—</>

  return (
    <div className="space-y-1 whitespace-normal">
      <div className="flex flex-wrap items-center gap-1">
        <HealthPill level={parseHealthLevel(instance.diskLevel)} />
        {instance.diskUsedPercent != null ? <span className="font-mono">{instance.diskUsedPercent.toFixed(1)}%</span> : null}
      </div>
      <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 text-2xs text-text-muted">
        <dt>Host</dt>
        <dd className="break-all font-mono text-text-primary">{instance.diskHostname || "—"}</dd>
        <dt>Path</dt>
        <dd className="break-all font-mono text-text-primary">{instance.diskPath || "—"}</dd>
        <dt>Available</dt>
        <dd className="font-mono text-text-primary">{formatBytesLarge(instance.diskAvailableBytes)}</dd>
        <dt>Total</dt>
        <dd className="font-mono text-text-primary">{formatBytesLarge(instance.diskTotalBytes)}</dd>
        <dt>Observed</dt>
        <dd className="break-all font-mono text-text-primary">{instance.diskObservedAt || "—"}</dd>
      </dl>
    </div>
  )
}

type VersionCard = {
  requestHandlerHostname: string | null
  requestHandlerRole: string | null
  requestHandlerVersion: string | null
  instances: InstanceRow[]
}

function parseVersionCard(context: ToolCardContext): VersionCard | null {
  if (context.resultError) return null
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

function collapsedSummary(context: ToolCardContext) {
  const card = parseVersionCard(context)
  if (!card) return null

  const versions = new Set(card.instances.map((instance) => instance.version).filter(Boolean))
  const mixed = versions.size > 1 ? " (mixed versions -- deploy in progress?)" : ""
  return `${card.instances.length} live instance${card.instances.length === 1 ? "" : "s"}${mixed}`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseVersionCard(context)
  if (!card) return null

  return (
    <CardShell>
      <dl className="grid gap-1 sm:grid-cols-3">
        <HeaderValue label="Handling host">{card.requestHandlerHostname ? <CopyableValue value={card.requestHandlerHostname} /> : <>—</>}</HeaderValue>
        <Row label="Role" value={card.requestHandlerRole ?? "—"} />
        <HeaderValue label="Version">
          <VersionValue value={card.requestHandlerVersion} />
        </HeaderValue>
      </dl>
      {card.instances.length === 0 ? (
        <EmptyState>No live instances found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["ID", "Host", "Role", "Version", "Started", "Heartbeat", "Disk"]} />
          <TBody>
            {card.instances.map((instance) => (
              <tr key={instance.key}>
                <Td mono>{instance.id || "—"}</Td>
                <Td primary wrap>
                  <span className="inline-flex flex-wrap items-center gap-1">
                    <CopyableValue value={instance.hostname} />
                    {instance.hostname === card.requestHandlerHostname &&
                    instance.role === card.requestHandlerRole &&
                    instance.version === card.requestHandlerVersion ? (
                      <span className="rounded bg-info-surface px-1 py-0.5 text-2xs font-semibold uppercase text-info-text">handler</span>
                    ) : null}
                  </span>
                </Td>
                <Td>{instance.role || "—"}</Td>
                <Td wrap>
                  <VersionValue value={instance.version} />
                </Td>
                <Td mono wrap>
                  {instance.startedAt || "—"}
                </Td>
                <Td mono wrap>
                  {instance.lastHeartbeatAt || "—"}
                </Td>
                <Td wrap>
                  <DiskUsage instance={instance} />
                </Td>
              </tr>
            ))}
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
