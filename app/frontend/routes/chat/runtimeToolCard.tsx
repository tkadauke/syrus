import i18n from "../../i18n"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { BANNER_TONE_CLASSES, type BannerTone } from "../../components/StatusPill"
import { MediaPreviewShell, type MediaPreviewAction } from "./mediaPreviewShell"
import { Badge, CardShell, Disclosure, FilterableList, displayValue, EmptyState, LargeTextPreview, Row, SectionLabel, StatePill } from "./toolCardUi"
import { TextPreview } from "./toolCardMarkdown"

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
  kind: string | null
  documentId: string | null
  pageUrl: string | null
  title: string | null
  viewport: string | null
  target: string | null
  createdAt: string | null
  warning: string | null
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
  | {
      kind: "lifecycle"
      action: RuntimeLifecycleAction
      session: RuntimeSession | null
      status: string | null
      url: string | null
      target: string | null
      command: string | null
      error: string | null
      raw: unknown
    }
  | {
      kind: "inspect"
      health: string | null
      framework: string | null
      ports: string | null
      processState: string | null
      warnings: string[]
      details: string | null
      raw: unknown
    }
  | { kind: "logs"; entries: string[]; cursor: string | null; nextCursor: string | null; raw: unknown }
  | { kind: "input"; event: RuntimeInputEvent; rawEvent: unknown; raw: unknown }
  | { kind: "snapshot"; snapshot: RuntimeSnapshot }
  | { kind: "artifact"; artifact: RuntimeArtifact }
  | { kind: "acquire"; lease: RuntimeLease | null; error: string | null; raw: unknown }
  | { kind: "release"; released: RuntimeLease[]; error: string | null; raw: unknown }
  | { kind: "error"; action: string; message: string; sessionId?: string | null }

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

  const text = value
    .flatMap((item) => {
      if (typeof item === "string") return [item]
      if (isPlainObject(item)) {
        const itemText = displayValue(item.text) ?? displayValue(item.content)
        return itemText ? [itemText] : []
      }
      return []
    })
    .join("\n")

  return text.trim() ? text : null
}

function contentItem(type: string, value: unknown): Record<string, unknown> | null {
  if (!Array.isArray(value)) return null
  return (value.find((item) => isPlainObject(item) && item.type === type) as Record<string, unknown> | undefined) ?? null
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
  const error =
    parsed.error === true
      ? firstDisplayValue(parsed.message, parsed.error_message, content)
      : firstDisplayValue(parsed.error, parsed.error_message, parsed.last_error)
  const explicitTarget =
    action === "launch" && !error ? firstDisplayValue(options.url, options.path, parsed.target, parsed.path, parsed.launch_target, parsed.url, content) : null

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
  const details = firstDisplayValue(parsed.summary, parsed.message, contentText(parsed.content), parsed.xml, parsed.tree, parsed.scrollback)

  return {
    kind: "inspect",
    health,
    framework: firstDisplayValue(parsed.framework, parsed.detected_framework, parsed.framework_name, metadata.framework),
    ports: portList(parsed.ports) ?? portList(parsed.port) ?? portList(metadata.ports) ?? portList(metadata.port),
    processState: firstDisplayValue(
      parsed.process_state,
      process.state,
      process.status,
      parsed.pid ? `pid ${displayValue(parsed.pid)}` : null,
      metadata.pid ? `pid ${displayValue(metadata.pid)}` : null
    ),
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
      valueSummary: valuePreview(event.value ?? event.text ?? event.data ?? event.input ?? event.keys),
      key: firstDisplayValue(event.key, event.code),
      delivered: typeof parsed.delivered === "boolean" ? parsed.delivered : error ? false : null,
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
  const error =
    parsed.error === true
      ? firstDisplayValue(parsed.message, contentText(parsed.content), parsed.error_message)
      : firstDisplayValue(parsed.error, parsed.error_message)

  return {
    kind: "snapshot",
    snapshot: {
      imageUrl: firstDisplayValue(
        parsed.image_url,
        parsed.preview_url,
        parsed.thumbnail_url,
        parsed.file_path,
        parsed.latest_frame_url,
        metadata.image_url,
        metadata.preview_url
      ),
      imageDataUrl: image.dataUrl,
      mimeType: firstDisplayValue(parsed.mime_type, parsed.mimeType, parsed.content_type, metadata.mime_type, image.mimeType),
      kind: firstDisplayValue(parsed.kind, metadata.kind),
      documentId: firstDisplayValue(parsed.document_id, parsed.artifact_id, metadata.document_id),
      pageUrl: firstDisplayValue(parsed.page_url, parsed.url, metadata.page_url, metadata.url),
      title: firstDisplayValue(parsed.title, parsed.page_title, metadata.title, parsed.kind),
      viewport: viewportLabel(
        parsed.viewport,
        metadata.viewport,
        parsed.viewport_width && parsed.viewport_height ? { width: parsed.viewport_width, height: parsed.viewport_height } : null,
        metadata.frame_width && metadata.frame_height ? { width: metadata.frame_width, height: metadata.frame_height } : null
      ),
      target: firstDisplayValue(options.target, options.element, parsed.target, parsed.element, parsed.kind),
      createdAt: firstDisplayValue(parsed.created_at, parsed.captured_at, parsed.latest_frame_at, metadata.created_at),
      warning: firstDisplayValue(parsed.warning, metadata.warning),
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
  const error =
    parsed.error === true
      ? firstDisplayValue(parsed.message, contentText(parsed.content), parsed.error_message)
      : firstDisplayValue(parsed.error, parsed.error_message)
  const id = firstDisplayValue(artifact.id, artifact.artifact_id, artifact.document_id, parsed.artifact_id, parsed.document_id)
  const name = firstDisplayValue(artifact.name, artifact.filename, artifact.title, artifact.kind)
  const path = firstDisplayValue(artifact.path, artifact.file_path)
  const link = firstDisplayValue(artifact.link, artifact.url, artifact.href)
  const previewUrl = firstDisplayValue(
    artifact.preview_url,
    artifact.thumbnail_url,
    artifact.image_url,
    artifact.file_path,
    artifact.latest_frame_url,
    image.dataUrl
  )
  const downloadUrl = firstDisplayValue(artifact.download_url, artifact.file_url, path)
  const missing = parsed.missing === true || parsed.found === false || (!error && !id && !name && !path && !link && !previewUrl && !downloadUrl)

  return {
    kind: "artifact",
    artifact: {
      id,
      name,
      type: firstDisplayValue(artifact.type, artifact.artifact_type, artifact.content_type, image.mimeType, artifact.kind, context.input?.artifact_type),
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
  if (isPlainObject(context.parsedResult))
    return displayValue(context.parsedResult.error) ?? displayValue(context.parsedResult.message) ?? displayValue(context.resultBody)
  return displayValue(context.resultBody)
}

function parseCard(context: ToolCardContext): RuntimeCard | null {
  const error = errorMessage(context)
  if (error) return { kind: "error", action: context.toolName, message: error, sessionId: displayValue(context.input?.session_id) }

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
    const statusPayload = isPlainObject(parsed.session_payload) ? parsed.session_payload : parsed
    const sessionId = firstDisplayValue(statusPayload.id, context.input?.session_id)
    if (parsed.error === true) {
      return {
        kind: "error",
        action: context.toolName,
        message:
          firstDisplayValue(parsed.message, parsed.error_message, contentText(parsed.content), statusPayload.last_error) ??
          i18n.t("chat:ops_runtime_status_failed_c100ee"),
        sessionId
      }
    }
    const session = parseSession({ ...statusPayload, id: sessionId })
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

  if (card.kind === "error") return i18n.t("chat:runtime_action_failed", { action: actionLabel(card.action) })
  if (card.kind === "sessions") {
    if (card.sessions.length === 0) return i18n.t("chat:ops_no_runtime_sessions_37f7e4")
    const primary = card.sessions.find((session) => session.primary) ?? card.sessions[0]
    const failing = card.sessions.filter((session) => session.state === "failed" || session.lastError).length
    return i18n.t("chat:runtime_sessions_summary", {
      count: card.sessions.length,
      id: primary.id,
      state: primary.state ?? i18n.t("chat:unknown"),
      lease: leaseLabel(primary.activeAgentInputLease),
      failures: failing > 0 ? i18n.t("chat:error_state_count", { count: failing }) : ""
    })
  }
  if (card.kind === "status") {
    const session = card.session
    return i18n.t("chat:runtime_status_summary", {
      id: session.id,
      state: session.state ?? i18n.t("chat:unknown"),
      lease: leaseLabel(session.activeAgentInputLease),
      error: session.lastError ? i18n.t("chat:error_suffix") : ""
    })
  }
  if (card.kind === "lifecycle") {
    const noun = lifecycleNoun(card.action)
    if (card.error) return i18n.t("chat:runtime_action_failed", { action: noun })
    const session = card.session ? i18n.t("chat:number_suffix", { id: card.session.id }) : ""
    const status = card.status ?? (card.action === "stop" ? (card.session?.state ?? "stopped") : "succeeded")
    const destination = card.target ?? card.url
    return i18n.t("chat:runtime_lifecycle_summary", {
      action: noun,
      session,
      status,
      destination: destination ? i18n.t("chat:at_destination", { value: destination }) : ""
    })
  }
  if (card.kind === "inspect") {
    const pieces = [card.health, card.framework, card.ports ? i18n.t("chat:ports_value", { value: card.ports }) : null, card.processState].filter(Boolean)
    const warningLabel = card.warnings.length > 0 ? i18n.t("chat:warning_count_suffix", { count: card.warnings.length }) : ""
    return pieces.length > 0
      ? i18n.t("chat:runtime_inspect_summary", { details: pieces.join(", "), warnings: warningLabel })
      : warningLabel
        ? i18n.t("chat:runtime_inspect_empty", { warnings: warningLabel })
        : i18n.t("chat:runtime_inspect_no_health_fields")
  }
  if (card.kind === "logs") {
    return card.entries.length === 0
      ? i18n.t("chat:ops_runtime_logs_no_new_lines_93527b")
      : i18n.t("chat:runtime_log_summary", {
          count: card.entries.length,
          cursor: card.nextCursor ? i18n.t("chat:cursor_suffix", { value: card.nextCursor }) : ""
        })
  }
  if (card.kind === "input") {
    if (card.event.error) return i18n.t("chat:runtime_input_failed", { error: card.event.error })
    const target = card.event.target ? i18n.t("chat:on_target", { value: card.event.target }) : ""
    const outcome = card.event.delivered === true ? i18n.t("chat:delivered") : i18n.t("chat:sent")
    return i18n.t("chat:runtime_input_summary", { outcome, event: card.event.type ?? i18n.t("chat:event"), target })
  }
  if (card.kind === "snapshot") {
    if (card.snapshot.error) return i18n.t("chat:ops_runtime_snapshot_failed_421e14")
    return i18n.t("chat:runtime_snapshot_captured", {
      target: card.snapshot.target ? i18n.t("chat:of_target", { value: card.snapshot.target }) : "",
      viewport: card.snapshot.viewport ? `, ${card.snapshot.viewport}` : ""
    })
  }
  if (card.kind === "artifact") {
    if (card.artifact.error) return i18n.t("chat:ops_runtime_artifact_capture_failed_8a5e95")
    if (card.artifact.missing) return i18n.t("chat:ops_no_runtime_artifact_captured_f4e043")
    return i18n.t("chat:runtime_artifact_captured", { artifact: card.artifact.name ?? card.artifact.id ?? card.artifact.type ?? i18n.t("chat:artifact") })
  }
  if (card.kind === "acquire") {
    if (card.error || !card.lease) return i18n.t("chat:ops_runtime_control_not_acquired_f3c058")
    return card.lease.owner === "agent" && card.lease.state === "active"
      ? i18n.t("chat:runtime_control_acquired", { mode: card.lease.mode ?? i18n.t("chat:lease"), id: card.lease.id })
      : i18n.t("chat:runtime_control_stale", { lease: leaseLabel(card.lease) })
  }
  if (card.kind === "release") {
    if (card.error) return i18n.t("chat:ops_runtime_control_release_failed_fc80a5")
    return card.released.length === 0
      ? i18n.t("chat:ops_no_runtime_control_leases_released_19d880")
      : i18n.t("chat:released_runtime_control_count", { count: card.released.length })
  }

  return null
}

function MetadataRows({ values }: { values: Record<string, unknown> }) {
  const entries = objectEntries(values).filter(([, value]) => displayValue(value) || typeof value === "boolean")
  if (entries.length === 0) return null

  return (
    <div>
      <SectionLabel>{i18n.t("chat:ops_metadata_251edc")}</SectionLabel>
      <div className="mt-1 grid gap-1 sm:grid-cols-2">
        {entries.map(([key, value]) => (
          <Row key={key} label={key} value={displayValue(value) ?? String(value)} wrap />
        ))}
      </div>
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

function latestFrameSource(session: RuntimeSession) {
  const latestFrameUrl = safeImageUrl(session.latestFrameUrl)
  if (!latestFrameUrl || !session.latestFrameAt || latestFrameUrl.startsWith("data:image/")) return latestFrameUrl

  const separator = latestFrameUrl.includes("?") ? "&" : "?"
  return `${latestFrameUrl}${separator}latest_frame_at=${encodeURIComponent(session.latestFrameAt)}`
}

function SafeLinks({ session }: { session: RuntimeSession }) {
  const links: Array<readonly [string, string]> = []
  const streamUrl = session.streamUrl ? safeRuntimeUrl(session.streamUrl) : null
  const latestFrameUrl = session.latestFrameUrl ? safeRuntimeUrl(session.latestFrameUrl) : null
  if (streamUrl) links.push([i18n.t("chat:ops_stream_df0638"), streamUrl])
  if (latestFrameUrl) links.push([i18n.t("chat:ops_latest_frame_c19a56"), latestFrameUrl])

  if (links.length === 0) return null

  return (
    <div>
      <SectionLabel>{i18n.t("chat:ops_urls_01f038")}</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-2">
        {links.map(([label, url]) => (
          <a
            className="inline-flex min-h-11 max-w-full items-center break-all font-mono text-brand hover:underline dark:text-brand-emphasis"
            href={url}
            key={label}
            rel="noreferrer"
            target="_blank"
          >
            {label}
          </a>
        ))}
      </div>
    </div>
  )
}

function LeaseDetails({ lease, title = i18n.t("chat:ops_control_ea1d3d") }: { lease: RuntimeLease | null; title?: string }) {
  if (!lease) return <StatePill state="no lease" tone="neutral" />

  return (
    <div className="rounded border border-gray-200 bg-white px-2 py-1 dark:border-gray-800 dark:bg-gray-950">
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={lease.state ?? "unknown"} tone={stateToneForLease(lease)} />
        <span className="break-words font-mono text-gray-700 dark:text-gray-300">
          {title} #{lease.id}
        </span>
        {lease.owner ? <Badge>{lease.owner}</Badge> : null}
        {lease.mode ? <Badge>{lease.mode}</Badge> : null}
      </div>
      <div className="mt-2 grid gap-1 sm:grid-cols-2">
        {lease.ownerRef ? <Row label={i18n.t("chat:ops_owner_ref_2d62db")} value={lease.ownerRef} wrap /> : null}
        {lease.reason ? <Row label={i18n.t("chat:ops_reason_f219cc")} value={lease.reason} wrap /> : null}
        {lease.acquiredAt ? <Row label={i18n.t("chat:ops_acquired_038f09")} value={lease.acquiredAt} /> : null}
        {lease.expiresAt ? <Row label={i18n.t("chat:ops_expires_a99be3")} value={lease.expiresAt} /> : null}
        {lease.cancellable != null ? <Row label={i18n.t("chat:ops_cancellable_24d26c")} value={lease.cancellable ? "yes" : "no"} /> : null}
      </div>
    </div>
  )
}

function RuntimeId({ id, href }: { id: string; href?: string | null }) {
  const label = i18n.t("chat:runtime_number", { id })
  return href ? (
    <a className="break-words font-mono text-brand hover:underline dark:text-brand-emphasis" href={href} rel="noreferrer" target="_blank">
      {label}
    </a>
  ) : (
    <span className="break-words font-mono text-gray-900 dark:text-gray-100">{label}</span>
  )
}

function RuntimeSessionBlock({ session }: { session: RuntimeSession }) {
  const frameSource = latestFrameSource(session)

  return (
    <div className="rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={session.state ?? "unknown"} />
        <RuntimeId href={session.streamUrl ? safeRuntimeUrl(session.streamUrl) : null} id={session.id} />
        {session.primary ? <Badge>primary</Badge> : null}
        {session.displayName ? <span className="text-gray-600 dark:text-gray-300">{session.displayName}</span> : null}
      </div>
      <div className="mt-2 grid gap-1 sm:grid-cols-3">
        {session.providerKey ? <Row label={i18n.t("chat:ops_provider_7ceee3")} value={session.providerKey} /> : null}
        {session.workspaceRef ? <Row label={i18n.t("chat:ops_workspace_4ca0a7")} value={session.workspaceRef} wrap /> : null}
        {session.latestFrameAt ? <Row label={i18n.t("chat:ops_latest_frame_at_3b2e7c")} value={session.latestFrameAt} /> : null}
      </div>
      <div className="mt-2 space-y-2">
        <SafeLinks session={session} />
        {frameSource ? (
          <MediaPreviewShell
            item={{
              title: i18n.t("chat:ops_latest_frame_c19a56"),
              subtitle: session.latestFrameAt,
              src: frameSource,
              alt: `Latest frame for Runtime #${session.id}`,
              actions: [{ label: i18n.t("chat:ops_open_cf9b77"), href: frameSource }],
              meta: [
                { label: i18n.t("chat:ops_runtime_c4740e"), value: session.id },
                { label: i18n.t("chat:ops_captured_e3d85d"), value: session.latestFrameAt }
              ]
            }}
            modalLabel={i18n.t("chat:ops_runtime_latest_frame_preview_9a08c6")}
          />
        ) : null}
        {session.lastError ? <LargeTextPreview label={i18n.t("chat:ops_last_error_5e4df8")} text={session.lastError} /> : null}
        <div>
          <SectionLabel>{i18n.t("chat:ops_control_owner_fce91c")}</SectionLabel>
          <div className="mt-1">
            <LeaseDetails lease={session.activeAgentInputLease} />
          </div>
        </div>
        <MetadataRows values={session.metadata} />
        {objectEntries(session.capabilities).length > 0 ? (
          <Disclosure label={i18n.t("chat:ops_capabilities_ca09c5")}>
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
    <div className="grid gap-1 sm:grid-cols-3">
      {visibleRows.map(([label, value]) => (
        <Row key={label} label={label} value={value} />
      ))}
    </div>
  )
}

function RawRuntimeDetails({ value }: { value: unknown }) {
  return (
    <Disclosure label={i18n.t("chat:ops_runtime_json_f2ba29")}>
      <pre className="overflow-x-auto whitespace-pre-wrap font-mono text-2xs">{JSON.stringify(value, null, 2)}</pre>
    </Disclosure>
  )
}

function RuntimeErrorCard({ message, sessionId }: { message: string; sessionId?: string | null }) {
  return (
    <CardShell>
      {sessionId ? <RuntimeId id={sessionId} /> : null}
      <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">{message}</div>
    </CardShell>
  )
}

function RuntimeNotice({ tone, message }: { tone: BannerTone; message: string }) {
  return <div className={`rounded border px-2 py-1 ${BANNER_TONE_CLASSES[tone]}`}>{message}</div>
}

function RuntimeLifecycleCard({ card }: { card: Extract<RuntimeCard, { kind: "lifecycle" }> }) {
  const tone = card.error ? "failure" : card.action === "stop" ? "neutral" : "success"
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={card.error ? "failed" : (card.status ?? (card.action === "stop" ? "stopped" : "succeeded"))} tone={tone} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{i18n.t("chat:runtime_lifecycle", { action: lifecycleNoun(card.action) })}</span>
        {card.session ? <span className="font-mono text-gray-700 dark:text-gray-300">#{card.session.id}</span> : null}
      </div>
      {card.error ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {card.error}
        </div>
      ) : null}
      <FieldRows
        rows={[
          [i18n.t("chat:ops_state_a72502"), card.session?.state ?? card.status],
          [i18n.t("chat:ops_command_890189"), card.command],
          ["URL", card.url],
          [i18n.t("chat:ops_launch_target_fc25c1"), card.target],
          [i18n.t("chat:ops_provider_7ceee3"), card.session?.providerKey ?? null],
          [i18n.t("chat:ops_workspace_4ca0a7"), card.session?.workspaceRef ?? null]
        ]}
      />
      {card.session ? <RuntimeSessionBlock session={card.session} /> : null}
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeInspectCard({ card }: { card: Extract<RuntimeCard, { kind: "inspect" }> }) {
  return (
    <CardShell>
      <FieldRows
        rows={[
          [i18n.t("chat:ops_health_3703cd"), card.health],
          [i18n.t("chat:ops_framework_fb001b"), card.framework],
          [i18n.t("chat:ops_ports_16c2eb"), card.ports],
          [i18n.t("chat:ops_process_12f4c1"), card.processState]
        ]}
      />
      {card.warnings.length > 0 ? (
        <div>
          <SectionLabel>{i18n.t("chat:ops_warnings_1430f9")}</SectionLabel>
          <ul className="mt-1 list-disc space-y-1 pl-4 text-amber-800 dark:text-amber-200">
            {card.warnings.map((warning, index) => (
              <li key={`${warning}-${index}`}>{warning}</li>
            ))}
          </ul>
        </div>
      ) : null}
      {card.details ? (
        <Disclosure label={i18n.t("chat:ops_inspection_details_f70991")}>
          <TextPreview text={card.details} truncate="headTail" />
        </Disclosure>
      ) : (
        <EmptyState>{i18n.t("chat:ops_no_detailed_inspection_output_was_returned_d52c57")}</EmptyState>
      )}
      <RawRuntimeDetails value={card.raw} />
    </CardShell>
  )
}

function RuntimeLogsCard({ card }: { card: Extract<RuntimeCard, { kind: "logs" }> }) {
  return (
    <CardShell>
      <FieldRows
        rows={[
          [i18n.t("chat:ops_lines_c6fd38"), String(card.entries.length)],
          [i18n.t("chat:ops_cursor_223994"), card.cursor],
          [i18n.t("chat:ops_next_cursor_0450c3"), card.nextCursor]
        ]}
      />
      {card.entries.length === 0 ? (
        <EmptyState>{i18n.t("chat:ops_no_new_runtime_log_lines_b62a93")}</EmptyState>
      ) : (
        <Disclosure label={i18n.t("chat:ops_log_preview_9e03df")}>
          <FilterableList itemText={(entry) => entry} items={card.entries} placeholder={i18n.t("chat:ops_filter_log_lines_9cf555")}>
            {(entries) => <TextPreview maxLines={40} text={entries.join("\n")} truncate="tail" />}
          </FilterableList>
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
        <span className="font-semibold text-gray-900 dark:text-gray-100">{card.event.type ?? i18n.t("chat:ops_runtime_input_5e0e20")}</span>
        {card.event.target ? <Badge>{card.event.target}</Badge> : null}
      </div>
      {card.event.error || card.event.message ? (
        <div
          className={
            card.event.error
              ? "rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
              : "text-gray-600 dark:text-gray-300"
          }
        >
          {card.event.message ?? card.event.error}
        </div>
      ) : null}
      <FieldRows
        rows={[
          [i18n.t("chat:ops_type_3deb74"), card.event.type],
          [i18n.t("chat:ops_target_61ad50"), card.event.target],
          [i18n.t("chat:ops_value_8dce17"), card.event.valueSummary],
          ["Key", card.event.key]
        ]}
      />
      <Disclosure label={i18n.t("chat:ops_input_event_6ec959")}>
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
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {snapshot.error}
        </div>
      ) : null}
      {snapshot.warning ? (
        <div className="rounded border border-amber-200 bg-amber-50 px-2 py-1 text-amber-800 dark:border-amber-900 dark:bg-amber-950/40 dark:text-amber-200">
          {snapshot.warning}
        </div>
      ) : null}
      {imageUrl ? (
        <MediaPreviewShell
          item={{
            title: snapshot.title ?? i18n.t("chat:ops_runtime_snapshot_32fa99"),
            subtitle: snapshot.pageUrl ?? snapshot.target,
            src: imageUrl,
            alt: i18n.t("chat:ops_runtime_snapshot_preview_738796"),
            badge: snapshot.mimeType?.split("/").pop()?.toUpperCase() ?? "image",
            actions: [
              { label: i18n.t("chat:ops_open_cf9b77"), href: imageUrl },
              { label: i18n.t("chat:ops_copy_link_2f84ee"), copyValue: imageUrl },
              snapshot.pageUrl ? { label: i18n.t("chat:ops_copy_page_092636"), copyValue: snapshot.pageUrl } : null
            ].filter(Boolean) as MediaPreviewAction[],
            meta: [
              { label: i18n.t("chat:ops_page_fb0627"), value: snapshot.pageUrl, copyValue: snapshot.pageUrl },
              { label: i18n.t("chat:ops_title_768e0c"), value: snapshot.title },
              { label: i18n.t("chat:ops_viewport_09e594"), value: snapshot.viewport },
              { label: i18n.t("chat:ops_target_61ad50"), value: snapshot.target },
              { label: i18n.t("chat:ops_kind_e00ac2"), value: snapshot.kind },
              { label: i18n.t("chat:ops_document_e214b8"), value: snapshot.documentId, copyValue: snapshot.documentId },
              { label: i18n.t("chat:ops_type_3deb74"), value: snapshot.mimeType },
              { label: i18n.t("chat:ops_captured_e3d85d"), value: snapshot.createdAt },
              { label: i18n.t("chat:ops_source_6da13a"), value: imageUrl, copyValue: imageUrl }
            ]
          }}
          modalLabel={i18n.t("chat:ops_runtime_snapshot_preview_738796")}
        />
      ) : (
        <EmptyState>{i18n.t("chat:ops_no_snapshot_preview_was_returned_08caad")}</EmptyState>
      )}
      <FieldRows
        rows={[
          [i18n.t("chat:ops_page_fb0627"), snapshot.pageUrl],
          [i18n.t("chat:ops_title_768e0c"), snapshot.title],
          [i18n.t("chat:ops_viewport_09e594"), snapshot.viewport],
          [i18n.t("chat:ops_target_61ad50"), snapshot.target],
          [i18n.t("chat:ops_kind_e00ac2"), snapshot.kind],
          [i18n.t("chat:ops_document_e214b8"), snapshot.documentId],
          [i18n.t("chat:ops_type_3deb74"), snapshot.mimeType],
          [i18n.t("chat:ops_captured_e3d85d"), snapshot.createdAt]
        ]}
      />
      <RawRuntimeDetails value={snapshot.raw} />
    </CardShell>
  )
}

function RuntimeArtifactCard({ card }: { card: Extract<RuntimeCard, { kind: "artifact" }> }) {
  const artifact = card.artifact
  const previewUrl = safeImageUrl(artifact.previewUrl)
  const downloadUrl = artifact.downloadUrl ? safeRuntimeUrl(artifact.downloadUrl) : null
  const link = artifact.link ? safeRuntimeUrl(artifact.link) : null
  const artifactTitle = artifact.name ?? artifact.id ?? i18n.t("chat:ops_runtime_artifact_55692f")

  return (
    <CardShell>
      {artifact.error ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          {artifact.error}
        </div>
      ) : artifact.missing ? (
        <EmptyState>{i18n.t("chat:ops_no_runtime_artifact_was_returned_cff771")}</EmptyState>
      ) : (
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="captured" tone="success" />
          <span className="font-semibold text-gray-900 dark:text-gray-100">{artifact.name ?? artifact.id ?? i18n.t("chat:ops_runtime_artifact_55692f")}</span>
          {artifact.type ? <Badge>{artifact.type}</Badge> : null}
        </div>
      )}
      {previewUrl ? (
        <MediaPreviewShell
          item={{
            title: artifactTitle,
            subtitle: artifact.path ?? artifact.type,
            src: previewUrl,
            alt: artifactTitle,
            badge: artifact.type?.split("/").pop()?.toUpperCase() ?? null,
            actions: [
              link ? { label: i18n.t("chat:ops_open_cf9b77"), href: link } : { label: i18n.t("chat:ops_open_cf9b77"), href: previewUrl },
              downloadUrl ? { label: i18n.t("chat:ops_download_a479c9"), href: downloadUrl, download: true } : null,
              artifact.id ? { label: i18n.t("chat:ops_copy_id_c44623"), copyValue: artifact.id } : null,
              artifact.path ? { label: i18n.t("chat:ops_copy_path_980455"), copyValue: artifact.path } : null
            ].filter(Boolean) as MediaPreviewAction[],
            meta: [
              { label: "ID", value: artifact.id, copyValue: artifact.id },
              { label: i18n.t("chat:ops_name_709a23"), value: artifact.name },
              { label: i18n.t("chat:ops_type_3deb74"), value: artifact.type },
              { label: i18n.t("chat:ops_path_519e39"), value: artifact.path, copyValue: artifact.path },
              { label: i18n.t("chat:ops_link_d05170"), value: link, copyValue: link },
              { label: i18n.t("chat:ops_download_a479c9"), value: downloadUrl, copyValue: downloadUrl }
            ]
          }}
          modalLabel={i18n.t("chat:ops_runtime_artifact_preview_a3e2ac")}
        />
      ) : null}
      <FieldRows
        rows={[
          ["ID", artifact.id],
          [i18n.t("chat:ops_name_709a23"), artifact.name],
          [i18n.t("chat:ops_type_3deb74"), artifact.type],
          [i18n.t("chat:ops_path_519e39"), artifact.path],
          [i18n.t("chat:ops_link_d05170"), link],
          [i18n.t("chat:ops_download_a479c9"), downloadUrl]
        ]}
      />
      <div className="flex flex-wrap gap-2">
        {link ? (
          <a className="font-mono text-brand hover:underline dark:text-brand-emphasis" href={link}>
            Open artifact
          </a>
        ) : null}
        {downloadUrl ? (
          <a className="font-mono text-brand hover:underline dark:text-brand-emphasis" href={downloadUrl}>
            Download
          </a>
        ) : null}
      </div>
      <RawRuntimeDetails value={artifact.raw} />
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return null

  if (card.kind === "error") return <RuntimeErrorCard message={card.message} sessionId={card.sessionId} />

  if (card.kind === "sessions") {
    return (
      <CardShell>
        {card.sessions.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_runtime_sessions_found_9af8cb")}</EmptyState>
        ) : (
          <div className="space-y-2">
            {card.sessions.map((session) => (
              <RuntimeSessionBlock key={session.id} session={session} />
            ))}
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
    const message = confirmed
      ? i18n.t("chat:ops_agent_owns_runtime_control_2ae73f")
      : (card.error ?? i18n.t("chat:ops_runtime_control_ownership_was_not_confirmed_910d15"))
    return (
      <CardShell>
        <RuntimeNotice message={message} tone={confirmed ? "success" : "warning"} />
        <LeaseDetails lease={card.lease} />
        <RawRuntimeDetails value={card.raw} />
      </CardShell>
    )
  }

  if (card.kind === "release") {
    return (
      <CardShell>
        {card.error ? (
          <RuntimeNotice message={card.error} tone="error" />
        ) : card.released.length === 0 ? (
          <EmptyState>{i18n.t("chat:ops_no_active_agent_runtime_control_leases_were_held_db0789")}</EmptyState>
        ) : (
          <div className="space-y-2">
            {card.released.map((lease) => (
              <LeaseDetails key={lease.id} lease={lease} title={i18n.t("chat:ops_released_lease_9f1464")} />
            ))}
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
