import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, Row, SectionLabel, StatePill, truncateLines } from "./toolCardUi"

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

type RuntimeLifecycleAction = "start" | "build/reload" | "launch" | "stop"

type RuntimeInputEvent = {
  type: string | null
  target: string | null
  valueSummary: string | null
  key: string | null
  delivered: boolean | null
  error: string | null
  message: string | null
}

type RuntimeSnapshot = {
  imageUrl: string | null
  imageDataUrl: string | null
  mimeType: string | null
  pageUrl: string | null
  title: string | null
  viewport: string | null
  target: string | null
  createdAt: string | null
  error: string | null
  raw: unknown
}

type RuntimeArtifact = {
  id: string | null
  name: string | null
  type: string | null
  path: string | null
  link: string | null
  previewUrl: string | null
  downloadUrl: string | null
  missing: boolean
  error: string | null
  raw: unknown
}

type RuntimeCard =
  | { kind: "sessions"; sessions: RuntimeSession[]; raw: unknown }
  | { kind: "status"; session: RuntimeSession; raw: unknown }
  | { kind: "lifecycle"; action: RuntimeLifecycleAction; session: RuntimeSession | null; status: string | null; url: string | null; target: string | null; command: string | null; error: string | null; raw: unknown }
  | { kind: "inspect"; health: string | null; framework: string | null; ports: string | null; processState: string | null; warnings: string[]; details: string | null; raw: unknown }
  | { kind: "logs"; entries: string[]; cursor: string | null; nextCursor: string | null; raw: unknown }
  | { kind: "input"; event: RuntimeInputEvent; rawEvent: unknown; raw: unknown }
  | { kind: "snapshot"; snapshot: RuntimeSnapshot }
  | { kind: "artifact"; artifact: RuntimeArtifact }
  | { kind: "acquire"; lease: RuntimeLease | null; error: string | null; raw: unknown }
  | { kind: "release"; released: RuntimeLease[]; error: string | null; raw: unknown }
  | { kind: "error"; action: string; message: string }

const LOG_PREVIEW_LINE_LIMIT = 40
const INPUT_VALUE_PREVIEW_LIMIT = 80

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function objectEntries(value: unknown): Array<[string, unknown]> {
  return isPlainObject(value) ? Object.entries(value) : []
}

function parseObject(value: unknown): Record<string, unknown> {
  return isPlainObject(value) ? value : {}
}

function firstDisplayValue(...values: unknown[]): string | null {
  for (const value of values) {
    const displayed = displayValue(value)
    if (displayed) return displayed
  }
  return null
}

function contentText(value: unknown): string | null {
  if (typeof value === "string") return value
  if (!Array.isArray(value)) return null

  const text = value.flatMap((item) => {
    if (typeof item === "string") return [item]
    if (isPlainObject(item)) {
      const itemText = displayValue(item.text) ?? displayValue(item.content)
      return itemText ? [itemText] : []
    }
    return []
  }).join("\n")

  return text.trim() ? text : null
}

function contentItem(type: string, value: unknown): Record<string, unknown> | null {
  if (!Array.isArray(value)) return null
  return value.find((item) => isPlainObject(item) && item.type === type) as Record<string, unknown> | undefined ?? null
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) {
    const displayed = displayValue(value)
    return displayed ? [displayed] : []
  }

  return value.flatMap((item) => {
    if (typeof item === "string") return item.trim() ? [item.trim()] : []
    if (!isPlainObject(item)) return []
    const displayed = firstDisplayValue(item.message, item.text, item.warning, item.detail, item.line)
    return displayed ? [displayed] : []
  })
}

function valuePreview(value: unknown): string | null {
  const displayed = displayValue(value)
  if (!displayed) return null
  return displayed.length > INPUT_VALUE_PREVIEW_LIMIT ? `${displayed.slice(0, INPUT_VALUE_PREVIEW_LIMIT)}...` : displayed
}

function portList(value: unknown): string | null {
  if (Array.isArray(value)) {
    const ports = value.flatMap((item) => {
      if (typeof item === "number" || typeof item === "string") {
        const displayed = displayValue(item)
        return displayed ? [displayed] : []
      }
      if (!isPlainObject(item)) return []
      const port = displayValue(item.port)
      const state = displayValue(item.state) ?? displayValue(item.status)
      if (!port) return []
      return [state ? `${port} ${state}` : port]
    })
    return ports.length > 0 ? ports.join(", ") : null
  }

  return displayValue(value)
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

function parseLifecycleCard(context: ToolCardContext, action: RuntimeLifecycleAction): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const session = parseSession(parsed)
  const metadata = parseObject(parsed.metadata)
  const options = parseObject(context.input?.options)
  const content = contentText(parsed.content)
  const error = parsed.error === true
    ? firstDisplayValue(parsed.message, parsed.error_message, content)
    : firstDisplayValue(parsed.error, parsed.error_message, parsed.last_error)
  const explicitTarget = action === "launch" && !error
    ? firstDisplayValue(options.url, options.path, parsed.target, parsed.path, parsed.launch_target, parsed.url, content)
    : null

  return {
    kind: "lifecycle",
    action,
    session,
    status: firstDisplayValue(parsed.command_status, parsed.build_status, parsed.status, parsed.state, session?.state),
    url: firstDisplayValue(parsed.url, metadata.url),
    target: explicitTarget,
    command: firstDisplayValue(parsed.command, parsed.build_command, metadata.command, metadata.pid ? `pid ${displayValue(metadata.pid)}` : null),
    error,
    raw: parsed
  }
}

function parseInspectCard(context: ToolCardContext): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const process = parseObject(parsed.process)
  const metadata = parseObject(parsed.metadata)
  const health = firstDisplayValue(parsed.health, parsed.app_health, parsed.status, parsed.state)
  const details = firstDisplayValue(parsed.summary, parsed.message, contentText(parsed.content), parsed.scrollback)

  return {
    kind: "inspect",
    health,
    framework: firstDisplayValue(parsed.framework, parsed.detected_framework, parsed.framework_name, metadata.framework),
    ports: portList(parsed.ports) ?? portList(parsed.port) ?? portList(metadata.ports) ?? portList(metadata.port),
    processState: firstDisplayValue(parsed.process_state, process.state, process.status, parsed.pid ? `pid ${displayValue(parsed.pid)}` : null, metadata.pid ? `pid ${displayValue(metadata.pid)}` : null),
    warnings: stringList(parsed.warnings).concat(stringList(parsed.warning)),
    details,
    raw: parsed
  }
}

function parseLogsCard(context: ToolCardContext): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.entries)) return null

  return {
    kind: "logs",
    entries: stringList(parsed.entries),
    cursor: displayValue(context.input?.cursor),
    nextCursor: firstDisplayValue(parsed.next_cursor, parsed.cursor),
    raw: parsed
  }
}

function parseInputCard(context: ToolCardContext): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const event = parseObject(context.input?.event)
  const eventType = firstDisplayValue(event.type, parsed.event_type, parsed.type)
  const error = firstDisplayValue(parsed.error, parsed.error_code)
  const message = firstDisplayValue(parsed.message, contentText(parsed.content))

  return {
    kind: "input",
    event: {
      type: eventType,
      target: firstDisplayValue(event.target, event.element, event.selector, parsed.target, parsed.element),
      valueSummary: valuePreview(event.value ?? event.text ?? event.input ?? event.keys),
      key: firstDisplayValue(event.key, event.code),
      delivered: typeof parsed.delivered === "boolean" ? parsed.delivered : (error ? false : null),
      error,
      message
    },
    rawEvent: event,
    raw: parsed
  }
}

function viewportLabel(...values: unknown[]): string | null {
  for (const value of values) {
    if (isPlainObject(value)) {
      const width = displayValue(value.width)
      const height = displayValue(value.height)
      if (width && height) return `${width}x${height}`
    }
    const displayed = displayValue(value)
    if (displayed) return displayed
  }
  return null
}

function imageDataUrl(content: unknown): { dataUrl: string | null; mimeType: string | null } {
  const image = contentItem("image", content)
  if (!image) return { dataUrl: null, mimeType: null }
  const mimeType = displayValue(image.mimeType) ?? displayValue(image.mime_type) ?? "image/png"
  const data = displayValue(image.data)
  if (!data) return { dataUrl: null, mimeType }
  if (data.startsWith("data:image/")) return { dataUrl: data, mimeType }
  return { dataUrl: `data:${mimeType};base64,${data}`, mimeType }
}

function parseSnapshotCard(context: ToolCardContext): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const metadata = parseObject(parsed.metadata)
  const options = parseObject(context.input?.options)
  const image = imageDataUrl(parsed.content)
  const error = parsed.error === true ? firstDisplayValue(parsed.message, contentText(parsed.content), parsed.error_message) : firstDisplayValue(parsed.error, parsed.error_message)

  return {
    kind: "snapshot",
    snapshot: {
      imageUrl: firstDisplayValue(parsed.image_url, parsed.preview_url, parsed.thumbnail_url, parsed.file_path, metadata.image_url, metadata.preview_url),
      imageDataUrl: image.dataUrl,
      mimeType: firstDisplayValue(parsed.mime_type, parsed.mimeType, metadata.mime_type, image.mimeType),
      pageUrl: firstDisplayValue(parsed.page_url, parsed.url, metadata.page_url, metadata.url),
      title: firstDisplayValue(parsed.title, parsed.page_title, metadata.title),
      viewport: viewportLabel(parsed.viewport, metadata.viewport, parsed.viewport_width && parsed.viewport_height ? { width: parsed.viewport_width, height: parsed.viewport_height } : null),
      target: firstDisplayValue(options.target, options.element, parsed.target, parsed.element),
      createdAt: firstDisplayValue(parsed.created_at, parsed.captured_at, metadata.created_at),
      error,
      raw: parsed
    }
  }
}

function parseArtifactCard(context: ToolCardContext): RuntimeCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const artifact = parseObject(parsed.artifact ?? parsed.media ?? parsed)
  const image = imageDataUrl(parsed.content)
  const error = parsed.error === true ? firstDisplayValue(parsed.message, contentText(parsed.content), parsed.error_message) : firstDisplayValue(parsed.error, parsed.error_message)
  const id = firstDisplayValue(artifact.id, artifact.artifact_id, parsed.artifact_id)
  const name = firstDisplayValue(artifact.name, artifact.filename, artifact.title)
  const path = firstDisplayValue(artifact.path, artifact.file_path)
  const link = firstDisplayValue(artifact.link, artifact.url, artifact.href)
  const previewUrl = firstDisplayValue(artifact.preview_url, artifact.thumbnail_url, artifact.image_url, image.dataUrl)
  const downloadUrl = firstDisplayValue(artifact.download_url, artifact.file_url, path)
  const missing = parsed.missing === true || parsed.found === false || (!error && !id && !name && !path && !link && !previewUrl && !downloadUrl)

  return {
    kind: "artifact",
    artifact: {
      id,
      name,
      type: firstDisplayValue(artifact.type, artifact.artifact_type, artifact.kind, context.input?.artifact_type, image.mimeType),
      path,
      link,
      previewUrl,
      downloadUrl,
      missing,
      error,
      raw: parsed
    }
  }
}

function errorMessage(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message) ?? displayValue(context.resultBody)
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

  if (context.toolName === "runtime_start") return parseLifecycleCard(context, "start")
  if (context.toolName === "runtime_build_or_reload") return parseLifecycleCard(context, "build/reload")
  if (context.toolName === "runtime_launch") return parseLifecycleCard(context, "launch")
  if (context.toolName === "runtime_inspect") return parseInspectCard(context)
  if (context.toolName === "runtime_logs") return parseLogsCard(context)
  if (context.toolName === "runtime_input") return parseInputCard(context)
  if (context.toolName === "runtime_snapshot") return parseSnapshotCard(context)
  if (context.toolName === "runtime_capture_artifact") return parseArtifactCard(context)
  if (context.toolName === "runtime_stop") return parseLifecycleCard(context, "stop")

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

function actionLabel(toolName: string) {
  return toolName.replace(/^runtime_/, "").replace(/_/g, " ")
}

function lifecycleNoun(action: RuntimeLifecycleAction) {
  if (action === "build/reload") return "build/reload"
  return action
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.kind === "error") return `Runtime ${actionLabel(card.action)} failed`
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
  if (card.kind === "lifecycle") {
    const noun = lifecycleNoun(card.action)
    if (card.error) return `Runtime ${noun} failed`
    const session = card.session ? ` #${card.session.id}` : ""
    const status = card.status ?? (card.action === "stop" ? card.session?.state ?? "stopped" : "succeeded")
    const destination = card.target ?? card.url
    return `Runtime ${noun}${session}: ${status}${destination ? ` at ${destination}` : ""}`
  }
  if (card.kind === "inspect") {
    const pieces = [card.health, card.framework, card.ports ? `ports ${card.ports}` : null, card.processState].filter(Boolean)
    const warningLabel = card.warnings.length > 0 ? `, ${plural(card.warnings.length, "warning")}` : ""
    return pieces.length > 0 ? `Runtime inspect: ${pieces.join(", ")}${warningLabel}` : `Runtime inspect${warningLabel || ": no health fields"}`
  }
  if (card.kind === "logs") {
    return card.entries.length === 0 ? "Runtime logs: no new lines" : `Runtime logs: ${plural(card.entries.length, "line")}${card.nextCursor ? `, cursor ${card.nextCursor}` : ""}`
  }
  if (card.kind === "input") {
    if (card.event.error) return `Runtime input failed: ${card.event.error}`
    const target = card.event.target ? ` on ${card.event.target}` : ""
    const outcome = card.event.delivered === true ? "delivered" : "sent"
    return `Runtime input ${outcome}: ${card.event.type ?? "event"}${target}`
  }
  if (card.kind === "snapshot") {
    if (card.snapshot.error) return "Runtime snapshot failed"
    const target = card.snapshot.target ? ` of ${card.snapshot.target}` : ""
    const viewport = card.snapshot.viewport ? `, ${card.snapshot.viewport}` : ""
    return `Runtime snapshot captured${target}${viewport}`
  }
  if (card.kind === "artifact") {
    if (card.artifact.error) return "Runtime artifact capture failed"
    if (card.artifact.missing) return "No Runtime artifact captured"
    return `Runtime artifact captured: ${card.artifact.name ?? card.artifact.id ?? card.artifact.type ?? "artifact"}`
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

function safeRuntimeUrl(url: string) {
  if (url.startsWith("/")) return url
  try {
    const parsed = new URL(url)
    if (parsed.protocol === "http:" || parsed.protocol === "https:") return url
  } catch (_error) {
    return null
  }

  return null
}

function safeImageUrl(url: string | null) {
  if (!url) return null
  if (url.startsWith("data:image/")) return url
  return safeRuntimeUrl(url)
}

function SafeLinks({ session }: { session: RuntimeSession }) {
  const links: Array<readonly [string, string]> = []
  const streamUrl = session.streamUrl ? safeRuntimeUrl(session.streamUrl) : null
  const latestFrameUrl = session.latestFrameUrl ? safeRuntimeUrl(session.latestFrameUrl) : null
  if (streamUrl) links.push(["Stream", streamUrl])
  if (latestFrameUrl) links.push(["Latest frame", latestFrameUrl])

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

function FieldRows({ rows }: { rows: Array<[string, string | null]> }) {
  const visibleRows = rows.filter(([, value]) => value) as Array<[string, string]>
  if (visibleRows.length === 0) return null

  return (
    <dl className="grid gap-1 sm:grid-cols-3">
      {visibleRows.map(([label, value]) => <Row key={label} label={label} value={value} />)}
    </dl>
  )
}

function RawRuntimeDetails({ value }: { value: unknown }) {
  return (
    <Disclosure label="Runtime JSON">
      <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-2xs">{JSON.stringify(value, null, 2)}</pre>
    </Disclosure>
  )
}

function RuntimeErrorCard({ message }: { message: string }) {
  return (
    <CardShell>
      <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
        {message}
      </div>
    </CardShell>
  )
}

function RuntimeLifecycleCard({ card }: { card: Extract<RuntimeCard, { kind: "lifecycle" }> }) {
  const tone = card.error ? "failure" : card.action === "stop" ? "neutral" : "success"
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.error ? "failed" : card.status ?? (card.action === "stop" ? "stopped" : "succeeded")} tone={tone} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">Runtime {lifecycleNoun(card.action)}</span>
        {card.session ? <span className="font-mono text-gray-700 dark:text-gray-300">#{card.session.id}</span> : null}
      </div>
      {card.error ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{card.error}</div>
      ) : null}
      <FieldRows rows={[
        ["State", card.session?.state ?? card.status],
        ["Command", card.command],
        ["URL", card.url],
        ["Launch target", card.target],
        ["Provider", card.session?.providerKey ?? null],
        ["Workspace", card.session?.workspaceRef ?? null]
      ]} />
      {card.session ? <RuntimeSessionBlock session={card.session} /> : null}
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeInspectCard({ card }: { card: Extract<RuntimeCard, { kind: "inspect" }> }) {
  return (
    <CardShell>
      <FieldRows rows={[
        ["Health", card.health],
        ["Framework", card.framework],
        ["Ports", card.ports],
        ["Process", card.processState]
      ]} />
      {card.warnings.length > 0 ? (
        <div>
          <SectionLabel>Warnings</SectionLabel>
          <ul className="mt-1 list-disc space-y-1 pl-4 text-amber-800 dark:text-amber-200">
            {card.warnings.map((warning, index) => <li key={`${warning}-${index}`}>{warning}</li>)}
          </ul>
        </div>
      ) : null}
      {card.details ? (
        <Disclosure label="Inspection details">
          <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{card.details}</pre>
        </Disclosure>
      ) : (
        <EmptyState>No detailed inspection output was returned.</EmptyState>
      )}
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeLogsCard({ card }: { card: Extract<RuntimeCard, { kind: "logs" }> }) {
  const text = card.entries.join("\n")
  const { preview, truncated, totalLines } = truncateLines(text, LOG_PREVIEW_LINE_LIMIT)

  return (
    <CardShell>
      <FieldRows rows={[
        ["Lines", String(card.entries.length)],
        ["Cursor", card.cursor],
        ["Next cursor", card.nextCursor]
      ]} />
      {card.entries.length === 0 ? (
        <EmptyState>No new Runtime log lines.</EmptyState>
      ) : (
        <Disclosure label="Log preview">
          <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
          {truncated ? <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">Showing first {LOG_PREVIEW_LINE_LIMIT} of {totalLines} lines.</div> : null}
        </Disclosure>
      )}
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeInputCard({ card }: { card: Extract<RuntimeCard, { kind: "input" }> }) {
  const tone = card.event.error ? "failure" : card.event.delivered === true ? "success" : "info"

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.event.error ? "failed" : card.event.delivered === true ? "delivered" : "sent"} tone={tone} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{card.event.type ?? "Runtime input"}</span>
        {card.event.target ? <Badge>{card.event.target}</Badge> : null}
      </div>
      {card.event.error || card.event.message ? (
        <div className={card.event.error ? "rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}>
          {card.event.message ?? card.event.error}
        </div>
      ) : null}
      <FieldRows rows={[
        ["Type", card.event.type],
        ["Target", card.event.target],
        ["Value", card.event.valueSummary],
        ["Key", card.event.key]
      ]} />
      <Disclosure label="Input event">
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{JSON.stringify(card.rawEvent, null, 2)}</pre>
      </Disclosure>
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeSnapshotCard({ card }: { card: Extract<RuntimeCard, { kind: "snapshot" }> }) {
  const snapshot = card.snapshot
  const imageUrl = safeImageUrl(snapshot.imageUrl ?? snapshot.imageDataUrl)

  return (
    <CardShell>
      {snapshot.error ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{snapshot.error}</div>
      ) : null}
      {imageUrl ? (
        <a className="block w-56 max-w-full overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950" href={imageUrl}>
          <img alt="Runtime snapshot preview" className="aspect-video w-full object-contain" src={imageUrl} />
          <span className="block px-2 py-1 text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Open preview</span>
        </a>
      ) : (
        <EmptyState>No snapshot preview was returned.</EmptyState>
      )}
      <FieldRows rows={[
        ["Page", snapshot.pageUrl],
        ["Title", snapshot.title],
        ["Viewport", snapshot.viewport],
        ["Target", snapshot.target],
        ["Type", snapshot.mimeType],
        ["Captured", snapshot.createdAt]
      ]} />
      <RawRuntimeDetails value={snapshot.raw} />
    </CardShell>
  )
}

function RuntimeArtifactCard({ card }: { card: Extract<RuntimeCard, { kind: "artifact" }> }) {
  const artifact = card.artifact
  const previewUrl = safeImageUrl(artifact.previewUrl)
  const downloadUrl = artifact.downloadUrl ? safeRuntimeUrl(artifact.downloadUrl) : null
  const link = artifact.link ? safeRuntimeUrl(artifact.link) : null

  return (
    <CardShell>
      {artifact.error ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{artifact.error}</div>
      ) : artifact.missing ? (
        <EmptyState>No Runtime artifact was returned.</EmptyState>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="captured" tone="success" />
          <span className="font-semibold text-gray-900 dark:text-gray-100">{artifact.name ?? artifact.id ?? "Runtime artifact"}</span>
          {artifact.type ? <Badge>{artifact.type}</Badge> : null}
        </div>
      )}
      {previewUrl ? (
        <a className="block w-56 max-w-full overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950" href={previewUrl}>
          <img alt={artifact.name ?? artifact.id ?? "Runtime artifact preview"} className="aspect-video w-full object-contain" src={previewUrl} />
          <span className="block px-2 py-1 text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">Open preview</span>
        </a>
      ) : null}
      <FieldRows rows={[
        ["ID", artifact.id],
        ["Name", artifact.name],
        ["Type", artifact.type],
        ["Path", artifact.path],
        ["Link", link],
        ["Download", downloadUrl]
      ]} />
      <div className="flex flex-wrap gap-2">
        {link ? <a className="font-mono text-brand hover:underline dark:text-brand-emphasis" href={link}>Open artifact</a> : null}
        {downloadUrl ? <a className="font-mono text-brand hover:underline dark:text-brand-emphasis" href={downloadUrl}>Download</a> : null}
      </div>
      <RawRuntimeDetails value={artifact.raw} />
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.kind === "error") return <RuntimeErrorCard message={card.message} />

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

  if (card.kind === "lifecycle") return <RuntimeLifecycleCard card={card} />

  if (card.kind === "inspect") return <RuntimeInspectCard card={card} />

  if (card.kind === "logs") return <RuntimeLogsCard card={card} />

  if (card.kind === "input") return <RuntimeInputCard card={card} />

  if (card.kind === "snapshot") return <RuntimeSnapshotCard card={card} />

  if (card.kind === "artifact") return <RuntimeArtifactCard card={card} />

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
