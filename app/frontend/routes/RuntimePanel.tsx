import { Fragment, useEffect, useRef, useState } from "react"
import type { ClipboardEvent, KeyboardEvent, PointerEvent } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import {
  RUNTIME_SESSION_ACTIVE_STATES,
  captureRuntimeArtifact,
  fetchRuntimeSessionLogs,
  fetchRuntimeSessions,
  releaseRuntimeControl,
  renewRuntimeControl,
  sendRuntimeInput,
  takeRuntimeControl,
  type RuntimeInputEvent,
  type RuntimeControlLease,
  type RuntimeSession
} from "../api/chats"
import { useT } from "../hooks/useT"
import { StatusPill } from "../components/StatusPill"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { Button } from "../components/Button"
import { errorMessage } from "../lib/errorMessage"
import { pluginRuntimeSessionViewComponentFor, runtimeSessionInputEnabled } from "../pluginRuntimeSessionViews"

const LOG_POLL_INTERVAL_MS = 4_000
const SESSION_POLL_INTERVAL_MS = 5_000
const FRAME_STALE_AFTER_MS = 30_000
const MAX_LOG_LINES = 500

// Take Control requests RuntimeControlLease::MAX_DURATION (the longest
// single lease the backend allows) up front, then the heartbeat below
// renews it in place well before it lapses -- DOC-17 leases are
// intentionally short-lived (15-60s) so an *unattended* claim expires
// quickly, but an operator actively working in the panel shouldn't lose
// control mid-task with no warning.
const TAKE_CONTROL_DURATION_SECONDS = 60
const RENEW_CHECK_INTERVAL_MS = 5_000
const RENEW_MARGIN_MS = 15_000

function runtimeSessionsQueryKey(chatId: string | number) {
  return ["chats", String(chatId), "runtime_sessions"] as const
}

function sessionIsActive(session: RuntimeSession | undefined): boolean {
  return Boolean(session && RUNTIME_SESSION_ACTIVE_STATES.includes(session.state))
}

function capabilityStrings(value: unknown): string[] {
  if (typeof value === "string") return [value]
  if (Array.isArray(value)) return value.filter((candidate): candidate is string => typeof candidate === "string")
  if (value && typeof value === "object") {
    return Object.values(value).flatMap(capabilityStrings)
  }

  return []
}

function sessionSupportsVisualFrames(session: RuntimeSession): boolean {
  const values = [
    ...capabilityStrings(session.capabilities.stream),
    ...capabilityStrings(session.capabilities.frame),
    ...capabilityStrings(session.capabilities.frames),
    ...capabilityStrings(session.capabilities.screenshot),
    ...capabilityStrings(session.capabilities.screenshots)
  ].map((value) => value.toLowerCase())

  return values.some((value) => ["frame", "frames", "image", "screenshot", "screenshots"].includes(value))
}

function latestFrameIsStale(session: RuntimeSession): boolean {
  if (!session.latest_frame_at || !sessionIsActive(session)) return false

  const capturedAtMs = new Date(session.latest_frame_at).getTime()
  return Number.isFinite(capturedAtMs) && Date.now() - capturedAtMs > FRAME_STALE_AFTER_MS
}

function latestFrameSource(session: RuntimeSession): string | null {
  if (!session.latest_frame_url) return null
  if (!session.latest_frame_at) return session.latest_frame_url

  const separator = session.latest_frame_url.includes("?") ? "&" : "?"
  return `${session.latest_frame_url}${separator}latest_frame_at=${encodeURIComponent(session.latest_frame_at)}`
}

// Cursor-based log tailing (DOC-17's "logs with cursor-based refresh"):
// fetches once immediately, then keeps polling and appending new entries
// while the session is still active. Resets whenever the selected session
// changes.
function useRuntimeLogs(chatId: string | number, sessionId: number | null, active: boolean) {
  const [entries, setEntries] = useState<string[]>([])
  const cursorRef = useRef<number | string>(0)

  useEffect(() => {
    setEntries([])
    cursorRef.current = 0
  }, [sessionId])

  useEffect(() => {
    if (sessionId == null) return undefined

    let cancelled = false

    async function poll() {
      if (sessionId == null) return
      try {
        const result = await fetchRuntimeSessionLogs(chatId, sessionId, cursorRef.current)
        if (cancelled) return
        cursorRef.current = result.cursor
        if (result.entries.length > 0) {
          setEntries((previous) => [...previous, ...result.entries].slice(-MAX_LOG_LINES))
        }
      } catch (_error) {
        // Transient fetch failures just retry on the next tick.
      }
    }

    void poll()
    if (!active) return undefined

    const interval = window.setInterval(poll, LOG_POLL_INTERVAL_MS)
    return () => {
      cancelled = true
      window.clearInterval(interval)
    }
  }, [chatId, sessionId, active])

  return entries
}

function ProviderMetadata({ session }: { session: RuntimeSession }) {
  const { t } = useT("chat")
  const entries = Object.entries(session.metadata || {}).filter(([, value]) => value !== null && value !== undefined && value !== "")

  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs text-gray-600 dark:text-gray-400">
      <dt className="font-medium text-gray-500 dark:text-gray-400">{t("runtime_provider")}</dt>
      <dd>{session.provider_key}</dd>
      <dt className="font-medium text-gray-500 dark:text-gray-400">{t("runtime_workspace_ref")}</dt>
      <dd className="truncate">{session.workspace_ref}</dd>
      {entries.map(([key, value]) => (
        <Fragment key={key}>
          <dt className="font-medium text-gray-500 dark:text-gray-400">{key}</dt>
          <dd className="truncate">{String(value)}</dd>
        </Fragment>
      ))}
    </dl>
  )
}

function GenericVisualFrame({
  chatId,
  inputEnabled,
  onSessionUpdate,
  session
}: {
  chatId: string | number
  inputEnabled: boolean
  onSessionUpdate: (session: RuntimeSession) => void
  session: RuntimeSession
}) {
  const { t } = useT("chat")
  const [streamFailed, setStreamFailed] = useState(false)
  const [imageLoaded, setImageLoaded] = useState(false)
  const [inputError, setInputError] = useState<string | null>(null)
  const imageRef = useRef<HTMLImageElement | null>(null)
  const visualStream = session.stream_url && sessionSupportsVisualFrames(session) ? session.stream_url : null
  const latestFrame = latestFrameSource(session)
  const frameSource = visualStream && !streamFailed ? visualStream : latestFrame
  const usingStream = Boolean(visualStream && frameSource === visualStream)
  const usingLatestFallback = Boolean(frameSource && !usingStream)
  const failed = session.state === "failed" || Boolean(session.last_error)
  const stale = usingLatestFallback && latestFrameIsStale(session)

  useEffect(() => {
    setStreamFailed(false)
  }, [session.id, session.stream_url])

  useEffect(() => {
    setImageLoaded(false)
  }, [frameSource])

  const runtimeInput = useMutation({
    mutationFn: (event: RuntimeInputEvent) => sendRuntimeInput(chatId, session.id, event),
    onSuccess: (result) => {
      setInputError(null)
      onSessionUpdate(result.runtime_session)
    },
    onError: (mutationError) => setInputError(errorMessage(mutationError, t("runtime_input_error")))
  })

  function pointerPayload(event: PointerEvent<HTMLDivElement>): RuntimeInputEvent | null {
    const image = imageRef.current
    if (!image) return null

    const rect = image.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) return null

    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    if (x < 0 || y < 0 || x > rect.width || y > rect.height) return null

    return {
      type: event.pointerType === "touch" ? "touch" : "pointer",
      action: "click",
      x,
      y,
      normalized_x: x / rect.width,
      normalized_y: y / rect.height,
      source_width: rect.width,
      source_height: rect.height,
      pointer_type: event.pointerType || "mouse",
      button: event.button
    }
  }

  function sendInput(event: RuntimeInputEvent) {
    if (!inputEnabled) return
    runtimeInput.mutate(event)
  }

  function handlePointerUp(event: PointerEvent<HTMLDivElement>) {
    if (!inputEnabled) return

    const payload = pointerPayload(event)
    if (!payload) return

    event.preventDefault()
    sendInput(payload)
  }

  function handleKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    if (!inputEnabled) return

    sendInput({
      type: "keyboard",
      action: "key_down",
      key: event.key,
      code: event.code,
      alt_key: event.altKey,
      ctrl_key: event.ctrlKey,
      meta_key: event.metaKey,
      shift_key: event.shiftKey,
      repeat: event.repeat
    })
  }

  function handlePaste(event: ClipboardEvent<HTMLDivElement>) {
    if (!inputEnabled) return

    const text = event.clipboardData.getData("text")
    if (!text) return

    event.preventDefault()
    sendInput({ type: "text", text })
  }

  let status = t("runtime_no_frame_yet")
  if (failed) {
    status = t("runtime_frame_disconnected")
  } else if (usingStream) {
    status = imageLoaded ? t("runtime_frame_live") : t("runtime_frame_refreshing")
  } else if (usingLatestFallback && visualStream) {
    status = t("runtime_frame_latest_fallback")
  } else if (stale) {
    status = t("runtime_frame_stale")
  } else if (usingLatestFallback) {
    status = t("runtime_frame_latest")
  }

  if (!frameSource) {
    return <p className={`text-xs ${failed ? "text-red-600 dark:text-red-400" : "text-gray-500 dark:text-gray-400"}`}>{status}</p>
  }

  return (
    <div>
      <div
        aria-disabled={!inputEnabled}
        aria-label={t("runtime_visual_input_surface")}
        className={inputEnabled ? "cursor-crosshair outline-none focus:ring-2 focus:ring-brand/40" : ""}
        onKeyDown={handleKeyDown}
        onPaste={handlePaste}
        onPointerUp={handlePointerUp}
        role="application"
        tabIndex={inputEnabled ? 0 : -1}
      >
        <img
          alt={t("runtime_latest_frame")}
          className="max-h-64 w-full rounded border border-gray-200 object-contain dark:border-gray-700"
          draggable={false}
          key={frameSource}
          onError={() => {
            if (usingStream && session.latest_frame_url) {
              setStreamFailed(true)
            }
          }}
          onLoad={() => setImageLoaded(true)}
          ref={imageRef}
          src={frameSource}
        />
      </div>
      <p
        className={`mt-1 text-xs ${failed ? "text-red-600 dark:text-red-400" : stale ? "text-amber-700 dark:text-amber-300" : "text-gray-400 dark:text-gray-500"}`}
      >
        {status}
        {usingLatestFallback && session.latest_frame_at ? (
          <>
            {" "}
            <RelativeTimestamp value={session.latest_frame_at} />
          </>
        ) : null}
      </p>
      {inputError ? <p className="mt-1 text-xs text-red-600 dark:text-red-400">{inputError}</p> : null}
    </div>
  )
}

function ControlPanel({
  chatId,
  session,
  myLease,
  onLeaseChange
}: {
  chatId: string | number
  session: RuntimeSession
  myLease: RuntimeControlLease | null
  onLeaseChange: (lease: RuntimeControlLease | null, session: RuntimeSession) => void
}) {
  const { t } = useT("chat")
  const [error, setError] = useState<string | null>(null)
  const agentLease = session.active_agent_input_lease

  const takeControl = useMutation({
    mutationFn: () => takeRuntimeControl(chatId, session.id, { reason: t("runtime_take_control_reason"), duration_seconds: TAKE_CONTROL_DURATION_SECONDS }),
    onSuccess: (result) => {
      setError(null)
      onLeaseChange(result.lease, result.runtime_session)
    },
    onError: (mutationError) => setError(errorMessage(mutationError, t("runtime_take_control_error")))
  })

  const releaseControl = useMutation({
    mutationFn: () => releaseRuntimeControl(chatId, session.id),
    onSuccess: (result) => {
      setError(null)
      onLeaseChange(null, result.runtime_session)
    },
    onError: (mutationError) => setError(errorMessage(mutationError, t("runtime_release_control_error")))
  })

  // A ref, not `renewControl.isPending`: the heartbeat effect below only
  // resets when the lease identity/expiry changes, so a closure capturing
  // the mutation object directly would read its `isPending` flag as it stood
  // at that render -- stale for as long as the interval keeps firing between
  // renews. A ref's `.current` is always read fresh regardless of which
  // render created the closure.
  const renewInFlightRef = useRef(false)

  const renewControl = useMutation({
    mutationFn: () => renewRuntimeControl(chatId, session.id, { duration_seconds: TAKE_CONTROL_DURATION_SECONDS }),
    onSuccess: (result) => {
      renewInFlightRef.current = false
      setError(null)
      onLeaseChange(result.lease, result.runtime_session)
    },
    onError: () => {
      // The heartbeat couldn't extend the lease (it already lapsed, or
      // someone/something else claimed the group in between) -- stop
      // pretending we still hold it instead of leaving a stale "You
      // (input)" badge with a Release Control button that does nothing.
      renewInFlightRef.current = false
      setError(t("runtime_control_lapsed"))
      onLeaseChange(null, session)
    }
  })

  // Heartbeat: while we hold an active "user" lease, renew it shortly before
  // it expires so a sustained Take Control session doesn't silently lapse
  // mid-task (DOC-17 leases are intentionally short -- 15-60s -- to keep an
  // *unattended* claim from lingering, not to interrupt active use).
  useEffect(() => {
    if (!myLease || myLease.owner !== "user" || !myLease.expires_at) return undefined

    const expiresAtMs = new Date(myLease.expires_at).getTime()
    if (Number.isNaN(expiresAtMs)) return undefined

    const tick = () => {
      if (renewInFlightRef.current) return
      if (expiresAtMs - Date.now() <= RENEW_MARGIN_MS) {
        renewInFlightRef.current = true
        renewControl.mutate()
      }
    }

    tick()
    const interval = window.setInterval(tick, RENEW_CHECK_INTERVAL_MS)
    return () => window.clearInterval(interval)
    // Deliberately depends only on lease identity/expiry, matching
    // useRuntimeLogs above -- not on `renewControl`/`onLeaseChange`, whose
    // identities change every render.
  }, [myLease?.id, myLease?.expires_at])

  const busy = takeControl.isPending || releaseControl.isPending
  const activeLease = agentLease ?? myLease

  return (
    <div className="space-y-2 rounded border border-gray-200 p-3 dark:border-gray-700">
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("runtime_control_label")}</span>
        <div className="flex items-center gap-1.5">
          {activeLease?.expires_at ? (
            <span className="text-[11px] text-gray-400 dark:text-gray-500">
              {t("runtime_control_expires_label")} <RelativeTimestamp value={activeLease.expires_at} />
            </span>
          ) : null}
          {agentLease ? (
            <span className="rounded-full bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-700 ring-1 ring-amber-200 dark:bg-amber-950/50 dark:text-amber-200 dark:ring-amber-800">
              {t("runtime_control_agent", { mode: agentLease.mode })}
            </span>
          ) : myLease ? (
            <span className="rounded-full bg-info/10 px-2 py-0.5 text-xs font-medium text-info ring-1 ring-info/30">
              {t("runtime_control_you", { mode: myLease.mode })}
            </span>
          ) : (
            <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">
              {t("runtime_control_none")}
            </span>
          )}
        </div>
      </div>
      <div className="flex gap-2">
        {agentLease ? (
          <Button disabled={busy} onClick={() => takeControl.mutate()} size="sm" type="button" variant="danger">
            {t("runtime_abort_agent_control")}
          </Button>
        ) : myLease ? (
          <Button disabled={busy} onClick={() => releaseControl.mutate()} size="sm" type="button" variant="secondary">
            {t("runtime_release_control")}
          </Button>
        ) : (
          <Button disabled={busy} onClick={() => takeControl.mutate()} size="sm" type="button" variant="secondary">
            {t("runtime_take_control")}
          </Button>
        )}
      </div>
      {error ? <p className="text-xs text-red-600 dark:text-red-400">{error}</p> : null}
    </div>
  )
}

function RuntimeSessionDetail({ chatId, session }: { chatId: string | number; session: RuntimeSession }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [myLease, setMyLease] = useState<RuntimeControlLease | null>(null)
  const [captureError, setCaptureError] = useState<string | null>(null)
  const active = sessionIsActive(session)
  const LiveView = pluginRuntimeSessionViewComponentFor(session.provider_key)
  const hasLiveView = LiveView !== null
  const logs = useRuntimeLogs(chatId, hasLiveView ? null : session.id, !hasLiveView && active)

  useEffect(() => {
    setMyLease(null)
  }, [session.id])

  function patchSession(updated: RuntimeSession) {
    queryClient.setQueryData<{ runtime_sessions: RuntimeSession[] } | undefined>(runtimeSessionsQueryKey(chatId), (current) =>
      current ? { runtime_sessions: current.runtime_sessions.map((candidate) => (candidate.id === updated.id ? updated : candidate)) } : current
    )
  }

  const capture = useMutation({
    mutationFn: () => captureRuntimeArtifact(chatId, session.id),
    onSuccess: (result) => {
      setCaptureError(null)
      patchSession(result.runtime_session)
      queryClient.invalidateQueries({ queryKey: ["chat_media", String(chatId)] })
    },
    onError: (mutationError) => setCaptureError(errorMessage(mutationError, t("runtime_capture_error")))
  })

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <StatusPill state={session.state} />
          <span className="text-sm font-medium text-gray-900 dark:text-gray-100">{session.display_name}</span>
        </div>
        {session.last_error ? (
          <span className="text-xs text-red-600 dark:text-red-400" title={session.last_error}>
            {t("runtime_last_error")}
          </span>
        ) : null}
      </div>

      <div className="space-y-1.5">
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{hasLiveView ? t("runtime_terminal_live") : t("runtime_latest_frame")}</span>
          <Button disabled={capture.isPending} onClick={() => capture.mutate()} size="sm" type="button" variant="secondary">
            {t("runtime_capture")}
          </Button>
        </div>
        {LiveView ? (
          <LiveView inputEnabled={runtimeSessionInputEnabled(session, myLease)} session={session} />
        ) : (
          <GenericVisualFrame chatId={chatId} inputEnabled={runtimeSessionInputEnabled(session, myLease)} onSessionUpdate={patchSession} session={session} />
        )}
        {captureError ? <p className="text-xs text-red-600 dark:text-red-400">{captureError}</p> : null}
      </div>

      <ControlPanel
        chatId={chatId}
        myLease={myLease}
        onLeaseChange={(lease, updatedSession) => {
          setMyLease(lease)
          patchSession(updatedSession)
        }}
        session={session}
      />

      {!hasLiveView ? (
        <div className="space-y-1">
          <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("runtime_logs")}</span>
          <pre className="max-h-40 overflow-y-auto whitespace-pre-wrap break-words rounded bg-gray-900 p-2 text-xs text-gray-100 dark:bg-black">
            {logs.length > 0 ? logs.join("\n") : t("runtime_logs_empty")}
          </pre>
        </div>
      ) : null}

      <ProviderMetadata session={session} />
    </div>
  )
}

export function RuntimePanel({ chatId }: { chatId: string | number }) {
  const { t } = useT("chat")
  const [selectedId, setSelectedId] = useState<number | null>(null)

  const { data, isLoading, isError } = useQuery({
    queryKey: runtimeSessionsQueryKey(chatId),
    queryFn: () => fetchRuntimeSessions(chatId),
    refetchInterval: (query) => {
      const sessions = query.state.data?.runtime_sessions ?? []
      return sessions.some((session) => sessionIsActive(session)) ? SESSION_POLL_INTERVAL_MS : false
    }
  })

  const sessions = data?.runtime_sessions ?? []

  useEffect(() => {
    if (sessions.length === 0) {
      setSelectedId(null)
      return
    }
    if (selectedId != null && sessions.some((session) => session.id === selectedId)) return

    const primary = sessions.find((session) => session.primary)
    setSelectedId((primary ?? sessions[0]).id)
    // Only re-derive the default selection when the session list itself
    // changes shape -- not on every `selectedId` update, which would
    // override an explicit user click back to the previous default.
  }, [sessions.map((session) => session.id).join(",")])

  if (isLoading) return <p className="text-sm text-gray-500 dark:text-gray-400">{t("runtime_loading")}</p>
  if (isError) return <p className="text-sm text-red-600 dark:text-red-400">{t("runtime_error")}</p>
  if (sessions.length === 0) return <p className="text-sm text-gray-500 dark:text-gray-400">{t("runtime_empty")}</p>

  const selected = sessions.find((session) => session.id === selectedId) ?? sessions[0]

  return (
    <div className="space-y-3">
      {sessions.length > 1 ? (
        <div className="flex flex-wrap gap-1.5">
          {sessions.map((session) => (
            <button
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${session.id === selected.id ? "bg-brand text-on-brand" : "bg-surface text-text-secondary ring-1 ring-border hover:bg-surface-raised"}`}
              key={session.id}
              onClick={() => setSelectedId(session.id)}
              type="button"
            >
              {session.display_name}
            </button>
          ))}
        </div>
      ) : null}
      <RuntimeSessionDetail chatId={chatId} key={selected.id} session={selected} />
    </div>
  )
}
