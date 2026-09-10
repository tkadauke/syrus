import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, Row, SectionLabel, StatePill } from "./toolCardUi"

type RuntimeLease = {
  id: string
  owner: string | null
  ownerRef: string | null
  mode: string | null
  reason: string | null
  state: string | null
  acquiredAt: string | null
  expiresAt: string | null
  cancellable: boolean | null
}

type RuntimeSession = {
  id: string
  providerKey: string | null
  displayName: string | null
  state: string | null
  primary: boolean
  workspaceRef: string | null
  capabilities: Record<string, unknown>
  metadata: Record<string, unknown>
  streamUrl: string | null
  latestFrameUrl: string | null
  latestFrameAt: string | null
  lastError: string | null
  activeAgentInputLease: RuntimeLease | null
}

type RuntimeCard =
  | { kind: "sessions"; sessions: RuntimeSession[]; raw: unknown }
  | { kind: "status"; session: RuntimeSession; raw: unknown }
  | { kind: "acquire"; lease: RuntimeLease | null; error: string | null; raw: unknown }
  | { kind: "release"; released: RuntimeLease[]; error: string | null; raw: unknown }
  | { kind: "error"; action: string; message: string }

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function objectEntries(value: unknown): Array<[string, unknown]> {
  return isPlainObject(value) ? Object.entries(value) : []
}

function parseObject(value: unknown): Record<string, unknown> {
  return isPlainObject(value) ? value : {}
}

function parseLease(value: unknown): RuntimeLease | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    id,
    owner: displayValue(value.owner),
    ownerRef: displayValue(value.owner_ref),
    mode: displayValue(value.mode),
    reason: displayValue(value.reason),
    state: displayValue(value.state),
    acquiredAt: displayValue(value.acquired_at),
    expiresAt: displayValue(value.expires_at),
    cancellable: typeof value.cancellable === "boolean" ? value.cancellable : null
  }
}

function parseSession(value: unknown): RuntimeSession | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    id,
    providerKey: displayValue(value.provider_key),
    displayName: displayValue(value.display_name),
    state: displayValue(value.state),
    primary: value.primary === true,
    workspaceRef: displayValue(value.workspace_ref),
    capabilities: parseObject(value.capabilities),
    metadata: parseObject(value.metadata),
    streamUrl: displayValue(value.stream_url),
    latestFrameUrl: displayValue(value.latest_frame_url),
    latestFrameAt: displayValue(value.latest_frame_at),
    lastError: displayValue(value.last_error),
    activeAgentInputLease: parseLease(value.active_agent_input_lease)
  }
}

function errorMessage(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message)
  return displayValue(context.resultBody)
}

function parseCard(context: ToolCardContext): RuntimeCard | null {
  const error = errorMessage(context)
  if (error) return { kind: "error", action: context.toolName, message: error }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  if (context.toolName === "runtime_list_sessions") {
    if (!Array.isArray(parsed.sessions)) return null
    return {
      kind: "sessions",
      sessions: parsed.sessions.flatMap((session) => {
        const parsedSession = parseSession(session)
        return parsedSession ? [parsedSession] : []
      }),
      raw: parsed
    }
  }

  if (context.toolName === "runtime_status") {
    const session = parseSession(parsed)
    return session ? { kind: "status", session, raw: parsed } : null
  }

  if (context.toolName === "runtime_acquire_control") {
    return { kind: "acquire", lease: parseLease(parsed), error: displayValue(parsed.error), raw: parsed }
  }

  if (context.toolName === "runtime_release_control") {
    if (!Array.isArray(parsed.released)) return null
    return {
      kind: "release",
      released: parsed.released.flatMap((lease) => {
        const parsedLease = parseLease(lease)
        return parsedLease ? [parsedLease] : []
      }),
      error: displayValue(parsed.error),
      raw: parsed
    }
  }

  return null
}

function plural(count: number, singular: string, pluralLabel = `${singular}s`) {
  return `${count} ${count === 1 ? singular : pluralLabel}`
}

function leaseLabel(lease: RuntimeLease | null): string {
  if (!lease) return "no active agent lease"
  const owner = lease.owner ?? "unknown owner"
  const mode = lease.mode ? `${lease.mode} ` : ""
  const state = lease.state ?? "unknown"
  return `${owner} ${mode}lease ${state}`.trim()
}

function stateToneForLease(lease: RuntimeLease | null): "success" | "failure" | "warning" | "info" | "neutral" {
  if (!lease) return "neutral"
  if (lease.owner === "agent" && lease.state === "active") return "success"
  if (lease.state === "active") return "warning"
  if (lease.state === "released") return "success"
  if (lease.state === "expired" || lease.state === "cancelled") return "warning"
  return "neutral"
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.kind === "error") return `Runtime ${card.action.replace(/^runtime_/, "").replace(/_/g, " ")} failed`
  if (card.kind === "sessions") {
    if (card.sessions.length === 0) return "No Runtime sessions"
    const primary = card.sessions.find((session) => session.primary) ?? card.sessions[0]
    const failing = card.sessions.filter((session) => session.state === "failed" || session.lastError).length
    return `${plural(card.sessions.length, "Runtime session")}: #${primary.id} ${primary.state ?? "unknown"}, ${leaseLabel(primary.activeAgentInputLease)}${failing > 0 ? `, ${plural(failing, "error state")}` : ""}`
  }
  if (card.kind === "status") {
    const session = card.session
    return `Runtime #${session.id}: ${session.state ?? "unknown"}, ${leaseLabel(session.activeAgentInputLease)}${session.lastError ? ", error" : ""}`
  }
  if (card.kind === "acquire") {
    if (card.error || !card.lease) return "Runtime control not acquired"
    return card.lease.owner === "agent" && card.lease.state === "active"
      ? `Runtime control acquired: ${card.lease.mode ?? "lease"} #${card.lease.id}`
      : `Runtime control stale: ${leaseLabel(card.lease)}`
  }
  if (card.kind === "release") {
    if (card.error) return "Runtime control release failed"
    return card.released.length === 0 ? "No Runtime control leases released" : `Released ${plural(card.released.length, "Runtime control lease")}`
  }

  return null
}

function MetadataRows({ values }: { values: Record<string, unknown> }) {
  const entries = objectEntries(values).filter(([, value]) => displayValue(value) || typeof value === "boolean")
  if (entries.length === 0) return null

  return (
    <div>
      <SectionLabel>Metadata</SectionLabel>
      <dl className="mt-1 grid gap-1 sm:grid-cols-2">
        {entries.map(([key, value]) => (
          <Row key={key} label={key} value={displayValue(value) ?? String(value)} />
        ))}
      </dl>
    </div>
  )
}

function SafeLinks({ session }: { session: RuntimeSession }) {
  const links: Array<readonly [string, string]> = []
  if (session.streamUrl) links.push(["Stream", session.streamUrl])
  if (session.latestFrameUrl) links.push(["Latest frame", session.latestFrameUrl])

  if (links.length === 0) return null

  return (
    <div>
      <SectionLabel>URLs</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-2">
        {links.map(([label, url]) => (
          <a className="font-mono text-brand hover:underline dark:text-brand-emphasis" href={url} key={label}>
            {label}
          </a>
        ))}
      </div>
    </div>
  )
}

function LeaseDetails({ lease, title = "Control" }: { lease: RuntimeLease | null; title?: string }) {
  if (!lease) return <StatePill state="no lease" tone="neutral" />

  return (
    <div className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={lease.state ?? "unknown"} tone={stateToneForLease(lease)} />
        <span className="font-mono text-gray-700 dark:text-gray-300">{title} #{lease.id}</span>
        {lease.owner ? <Badge>{lease.owner}</Badge> : null}
        {lease.mode ? <Badge>{lease.mode}</Badge> : null}
      </div>
      <dl className="mt-2 grid gap-1 sm:grid-cols-2">
        {lease.ownerRef ? <Row label="Owner ref" value={lease.ownerRef} /> : null}
        {lease.reason ? <Row label="Reason" value={lease.reason} /> : null}
        {lease.acquiredAt ? <Row label="Acquired" value={lease.acquiredAt} /> : null}
        {lease.expiresAt ? <Row label="Expires" value={lease.expiresAt} /> : null}
        {lease.cancellable != null ? <Row label="Cancellable" value={lease.cancellable ? "yes" : "no"} /> : null}
      </dl>
    </div>
  )
}

function RuntimeSessionBlock({ session }: { session: RuntimeSession }) {
  return (
    <div className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={session.state ?? "unknown"} />
        <span className="font-mono text-gray-900 dark:text-gray-100">Runtime #{session.id}</span>
        {session.primary ? <Badge>primary</Badge> : null}
        {session.displayName ? <span className="text-gray-600 dark:text-gray-300">{session.displayName}</span> : null}
      </div>
      <dl className="mt-2 grid gap-1 sm:grid-cols-3">
        {session.providerKey ? <Row label="Provider" value={session.providerKey} /> : null}
        {session.workspaceRef ? <Row label="Workspace" value={session.workspaceRef} /> : null}
        {session.latestFrameAt ? <Row label="Latest frame at" value={session.latestFrameAt} /> : null}
      </dl>
      <div className="mt-2 space-y-2">
        <SafeLinks session={session} />
        {session.lastError ? (
          <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
            {session.lastError}
          </div>
        ) : null}
        <div>
          <SectionLabel>Control owner</SectionLabel>
          <div className="mt-1"><LeaseDetails lease={session.activeAgentInputLease} /></div>
        </div>
        <MetadataRows values={session.metadata} />
        {objectEntries(session.capabilities).length > 0 ? (
          <Disclosure label="Capabilities">
            <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-2xs">{JSON.stringify(session.capabilities, null, 2)}</pre>
          </Disclosure>
        ) : null}
      </div>
    </div>
  )
}

function RawRuntimeDetails({ value }: { value: unknown }) {
  return (
    <Disclosure label="Runtime JSON">
      <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-2xs">{JSON.stringify(value, null, 2)}</pre>
    </Disclosure>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.kind === "error") {
    return (
      <CardShell>
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {card.message}
        </div>
      </CardShell>
    )
  }

  if (card.kind === "sessions") {
    return (
      <CardShell>
        {card.sessions.length === 0 ? (
          <EmptyState>No Runtime sessions found.</EmptyState>
        ) : (
          <div className="space-y-2">
            {card.sessions.map((session) => <RuntimeSessionBlock key={session.id} session={session} />)}
          </div>
        )}
        <RawRuntimeDetails value={card.raw} />
      </CardShell>
    )
  }

  if (card.kind === "status") {
    return (
      <CardShell>
        <RuntimeSessionBlock session={card.session} />
        <RawRuntimeDetails value={card.raw} />
      </CardShell>
    )
  }

  if (card.kind === "acquire") {
    const confirmed = card.lease?.owner === "agent" && card.lease.state === "active"
    return (
      <CardShell>
        <div className={confirmed ? "rounded border border-emerald-200 bg-emerald-50 px-2 py-1 text-emerald-700 dark:border-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-300" : "rounded border border-amber-200 bg-amber-50 px-2 py-1 text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200"}>
          {confirmed ? "Agent owns Runtime control." : card.error ?? "Runtime control ownership was not confirmed."}
        </div>
        <LeaseDetails lease={card.lease} />
        <RawRuntimeDetails value={card.raw} />
      </CardShell>
    )
  }

  if (card.kind === "release") {
    return (
      <CardShell>
        {card.error ? (
          <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{card.error}</div>
        ) : card.released.length === 0 ? (
          <EmptyState>No active agent Runtime control leases were held.</EmptyState>
        ) : (
          <div className="space-y-2">
            {card.released.map((lease) => <LeaseDetails key={lease.id} lease={lease} title="Released lease" />)}
          </div>
        )}
        <RawRuntimeDetails value={card.raw} />
      </CardShell>
    )
  }

  return null
}

export function runtimeToolCardRenderer(toolName: string): ToolCardRenderer {
  return { toolName, collapsedSummary, renderExpanded }
}
