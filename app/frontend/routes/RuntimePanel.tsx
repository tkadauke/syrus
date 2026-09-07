import { Fragment, useEffect, useRef, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import {
  RUNTIME_SESSION_ACTIVE_STATES,
  captureRuntimeArtifact,
  fetchRuntimeSessionLogs,
  fetchRuntimeSessions,
  releaseRuntimeControl,
  takeRuntimeControl,
  type RuntimeControlLease,
  type RuntimeSession
} from "../api/chats"
import { useT } from "../hooks/useT"
import { StatusPill } from "../components/StatusPill"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { Button } from "../components/Button"
import { errorMessage } from "../lib/errorMessage"

const LOG_POLL_INTERVAL_MS = 4_000
const SESSION_POLL_INTERVAL_MS = 5_000
const MAX_LOG_LINES = 500

function runtimeSessionsQueryKey(chatId: string | number) {
  return [ "chats", String(chatId), "runtime_sessions" ] as const
}

function sessionIsActive(session: RuntimeSession | undefined): boolean {
  return Boolean(session && RUNTIME_SESSION_ACTIVE_STATES.includes(session.state))
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
    mutationFn: () => takeRuntimeControl(chatId, session.id, { reason: t("runtime_take_control_reason") }),
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

  const busy = takeControl.isPending || releaseControl.isPending

  return (
    <div className="space-y-2 rounded border border-gray-200 p-3 dark:border-gray-700">
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("runtime_control_label")}</span>
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
  const [ captureError, setCaptureError ] = useState<string | null>(null)
  const active = sessionIsActive(session)
  const logs = useRuntimeLogs(chatId, session.id, active)

  useEffect(() => {
    setMyLease(null)
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
        <div className="flex items-center justify-between">
          <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("runtime_latest_frame")}</span>
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
        {session.latest_frame_url ? (
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

      <div className="space-y-1">
        <span className="text-xs font-medium text-gray-500 dark:text-gray-400">{t("runtime_logs")}</span>
        <pre className="max-h-40 overflow-y-auto whitespace-pre-wrap break-words rounded bg-gray-900 p-2 text-xs text-gray-100 dark:bg-black">
          {logs.length > 0 ? logs.join("\n") : t("runtime_logs_empty")}
        </pre>
      </div>

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
