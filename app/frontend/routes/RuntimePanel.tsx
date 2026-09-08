import { Fragment, useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import {
  RUNTIME_SESSION_ACTIVE_STATES,
  captureRuntimeArtifact,
  fetchRuntimeSessionLogs,
  fetchRuntimeSessions,
  releaseRuntimeControl,
  renewRuntimeControl,
  takeRuntimeControl,
  type RuntimeControlLease,
  type RuntimeSession
} from "../api/chats"
import { useT } from "../hooks/useT"
import { StatusPill } from "../components/StatusPill"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { Button } from "../components/Button"
import { errorMessage } from "../lib/errorMessage"
import { TerminalStream, type TerminalConnectionState } from "@plugins/terminal/app/frontend/components/TerminalStream"

const LOG_POLL_INTERVAL_MS = 4_000
const SESSION_POLL_INTERVAL_MS = 5_000
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
  return [ "chats", String(chatId), "runtime_sessions" ] as const
}

function sessionIsActive(session: RuntimeSession | undefined): boolean {
  return Boolean(session && RUNTIME_SESSION_ACTIVE_STATES.includes(session.state))
}

function runtimeTerminalSessionId(session: RuntimeSession): number | null {
  if (session.provider_key !== "cli_tui") return null

  const value = session.metadata?.terminal_session_id
  const id = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN
  return Number.isInteger(id) && id > 0 ? id : null
}

// Cursor-based log tailing (DOC-17's "logs with cursor-based refresh"):
// fetches once immediately, then keeps polling and appending new entries
// while the session is still active. Resets whenever the selected session
// changes.
function useRuntimeLogs(chatId: string | number, sessionId: number | null, active: boolean) {
  const [ entries, setEntries ] = useState<string[]>([])
  const cursorRef = useRef<number | string>(0)

  useEffect(() => {
    setEntries([])
    cursorRef.current = 0
  }, [ sessionId ])

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
          setEntries((previous) => [ ...previous, ...result.entries ].slice(-MAX_LOG_LINES))
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
  }, [ chatId, sessionId, active ])

  return entries
}

function ProviderMetadata({ session }: { session: RuntimeSession }) {
  const { t } = useT("chat")
  const entries = Object.entries(session.metadata || {}).filter(([ , value ]) => value !== null && value !== undefined && value !== "")

  return (
    <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-xs text-gray-600 dark:text-gray-400">
      <dt className="font-medium text-gray-500 dark:text-gray-400">{t("runtime_provider")}</dt>
      <dd>{session.provider_key}</dd>
      <dt className="font-medium text-gray-500 dark:text-gray-400">{t("runtime_workspace_ref")}</dt>
      <dd className="truncate">{session.workspace_ref}</dd>
      {entries.map(([ key, value ]) => (
        <Fragment key={key}>
          <dt className="font-medium text-gray-500 dark:text-gray-400">{key}</dt>
          <dd className="truncate">{String(value)}</dd>
        </Fragment>
      ))}
    </dl>
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
  const [ error, setError ] = useState<string | null>(null)
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
  }, [ myLease?.id, myLease?.expires_at ])

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
          <Button
            disabled={busy}
            onClick={() => takeControl.mutate()}
            size="sm"
            type="button"
            variant="danger"
          >
            {t("runtime_abort_agent_control")}
          </Button>
        ) : myLease ? (
          <Button
            disabled={busy}
            onClick={() => releaseControl.mutate()}
            size="sm"
            type="button"
            variant="secondary"
          >
            {t("runtime_release_control")}
          </Button>
        ) : (
          <Button
            disabled={busy}
            onClick={() => takeControl.mutate()}
            size="sm"
            type="button"
            variant="secondary"
          >
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
  const [ myLease, setMyLease ] = useState<RuntimeControlLease | null>(null)
  const [ terminalConnection, setTerminalConnection ] = useState<TerminalConnectionState>({ connected: true, ended: false })
  const [ captureError, setCaptureError ] = useState<string | null>(null)
  const active = sessionIsActive(session)
  const terminalSessionId = runtimeTerminalSessionId(session)
  const logs = useRuntimeLogs(chatId, terminalSessionId == null ? session.id : null, terminalSessionId == null && active)

  useEffect(() => {
    setMyLease(null)
    setTerminalConnection({ connected: true, ended: false })
  }, [ session.id ])

  function patchSession(updated: RuntimeSession) {
    queryClient.setQueryData<{ runtime_sessions: RuntimeSession[] } | undefined>(
      runtimeSessionsQueryKey(chatId),
      (current) => current ? { runtime_sessions: current.runtime_sessions.map((candidate) => candidate.id === updated.id ? updated : candidate) } : current
    )
  }

  const capture = useMutation({
    mutationFn: () => captureRuntimeArtifact(chatId, session.id),
    onSuccess: (result) => {
      setCaptureError(null)
      patchSession(result.runtime_session)
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
          <span className="text-xs text-red-600 dark:text-red-400" title={session.last_error}>{t("runtime_last_error")}</span>
        ) : null}
      </div>

      <div className="space-y-1.5">
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs font-medium text-gray-500 dark:text-gray-400">
            {terminalSessionId == null ? t("runtime_latest_frame") : t("runtime_terminal_live")}
          </span>
          <Button
            disabled={capture.isPending}
            onClick={() => capture.mutate()}
            size="sm"
            type="button"
            variant="secondary"
          >
            {t("runtime_capture")}
          </Button>
        </div>
        {terminalSessionId != null ? (
          <div>
            <TerminalStream
              className="relative h-72 min-h-0 overflow-hidden rounded border border-gray-200 dark:border-gray-700"
              containerClassName="h-full overflow-hidden bg-gray-900 p-2"
              inputEnabled={Boolean(myLease && myLease.owner === "user" && myLease.mode === "input" && !session.active_agent_input_lease)}
              onConnectionChange={setTerminalConnection}
              terminalSessionId={terminalSessionId}
            />
            <p className={`mt-1 text-xs ${terminalConnection.connected ? "text-emerald-600 dark:text-emerald-400" : "text-gray-500 dark:text-gray-400"}`}>
              {terminalConnection.connected ? t("runtime_terminal_connected") : t("runtime_terminal_disconnected")}
            </p>
          </div>
        ) : session.latest_frame_url ? (
          <div>
            <img
              alt={t("runtime_latest_frame")}
              className="max-h-64 w-full rounded border border-gray-200 object-contain dark:border-gray-700"
              key={session.latest_frame_url}
              src={session.latest_frame_url}
            />
            <p className="mt-1 text-xs text-gray-400 dark:text-gray-500">
              <RelativeTimestamp value={session.latest_frame_at} />
            </p>
          </div>
        ) : (
          <p className="text-xs text-gray-500 dark:text-gray-400">{t("runtime_no_frame_yet")}</p>
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

      {terminalSessionId == null ? (
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
  const [ selectedId, setSelectedId ] = useState<number | null>(null)

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
  }, [ sessions.map((session) => session.id).join(",") ])

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
              className={`rounded-full px-2.5 py-1 text-xs font-medium ${session.id === selected.id ? "bg-brand text-on-brand" : "bg-gray-100 text-gray-600 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"}`}
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
