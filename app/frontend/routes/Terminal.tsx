import "xterm/css/xterm.css"

import { createConsumer, type Subscription } from "@rails/actioncable"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { FitAddon } from "@xterm/addon-fit"
import { SerializeAddon } from "@xterm/addon-serialize"
import { Terminal } from "xterm"
import { useEffect, useMemo, useRef, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { createTerminalSession, fetchTerminalSessions, killTerminalSession, type TerminalSessionRecord, type TerminalSessionsPayload } from "../api/terminal"
import { CloseIcon } from "../components/CloseIcon"

const terminalSessionsQueryKey = ["terminal_sessions"] as const
const terminalSnapshots = new Map<number, string>()

export function TerminalRoute() {
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const bootstrap = useQuery<BootstrapPayload>({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: false
  })
  const terminalEnabled = Boolean(bootstrap.data?.feature_flags?.terminal)
  const [activeSessionId, setActiveSessionId] = useState<number | null>(() => {
    const id = Number(new URLSearchParams(location.search).get("session"))
    return Number.isFinite(id) && id > 0 ? id : null
  })
  const [workspacePickerOpen, setWorkspacePickerOpen] = useState(false)

  const sessionsQuery = useQuery({
    queryKey: terminalSessionsQueryKey,
    queryFn: ({ signal }) => fetchTerminalSessions({ signal }),
    enabled: terminalEnabled,
    refetchInterval: terminalEnabled ? 5000 : false
  })

  const sessions = sessionsQuery.data?.sessions ?? []
  const workspaces = sessionsQuery.data?.workspaces ?? []
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[0] ?? null

  const createMutation = useMutation({
    mutationFn: createTerminalSession,
    onSuccess(payload) {
      queryClient.setQueryData(terminalSessionsQueryKey, (current: TerminalSessionsPayload | undefined) => {
        if (!current) return { sessions: [payload.session], workspaces: [] }
        return {
          ...current,
          sessions: [payload.session, ...current.sessions.filter((session) => session.id !== payload.session.id)]
        }
      })
      setActiveSessionId(payload.session.id)
      setWorkspacePickerOpen(false)
      navigate(`?session=${payload.session.id}`, { replace: true })
    }
  })

  const killMutation = useMutation({
    mutationFn: killTerminalSession,
    onSuccess(payload) {
      queryClient.setQueryData(terminalSessionsQueryKey, (current: TerminalSessionsPayload | undefined) => {
        if (!current) return current
        return {
          ...current,
          sessions: current.sessions.filter((session) => session.id !== payload.session.id)
        }
      })
      if (activeSessionId === payload.session.id) {
        const remaining = sessions.filter((session) => session.id !== payload.session.id)
        setActiveSessionId(remaining[0]?.id ?? null)
      }
    }
  })

  useEffect(() => {
    const id = Number(new URLSearchParams(location.search).get("session"))
    if (Number.isFinite(id) && id > 0) setActiveSessionId(id)
  }, [location.search])

  useEffect(() => {
    if (!activeSessionId && sessions[0]) setActiveSessionId(sessions[0].id)
  }, [activeSessionId, sessions])

  return (
    <main aria-label="Terminal" className="flex h-screen flex-col overflow-hidden bg-gray-950 text-gray-100">
      <div className="flex min-h-0 flex-1 flex-col">
        <div className="flex shrink-0 items-center gap-2 border-b border-gray-800 bg-gray-900 px-3 py-2">
          <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto" role="tablist" aria-label="Terminal sessions">
            {sessions.map((session) => (
              <div
                className={`group inline-flex h-9 min-w-0 max-w-64 items-center gap-2 rounded border px-2 text-sm ${activeSession?.id === session.id ? "border-blue-500 bg-blue-950 text-white" : "border-gray-700 bg-gray-900 text-gray-300 hover:border-gray-600 hover:bg-gray-800"}`}
                key={session.id}
              >
                <button
                  aria-selected={activeSession?.id === session.id}
                  className="min-w-0 truncate"
                  onClick={() => {
                    setActiveSessionId(session.id)
                    navigate(`?session=${session.id}`, { replace: true })
                  }}
                  role="tab"
                  type="button"
                >
                  {session.name}
                </button>
                <button
                  aria-label={`Close ${session.name}`}
                  className="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-gray-400 hover:bg-gray-700 hover:text-white disabled:opacity-50"
                  disabled={killMutation.isPending}
                  onClick={() => killMutation.mutate(session.id)}
                  type="button"
                >
                  <CloseIcon className="h-3.5 w-3.5" />
                </button>
              </div>
            ))}
          </div>
          <div className="relative shrink-0">
            <button
              aria-expanded={workspacePickerOpen}
              aria-haspopup="menu"
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-700 bg-gray-900 text-lg font-semibold text-gray-100 hover:border-blue-500 hover:text-blue-300"
              onClick={() => setWorkspacePickerOpen((open) => !open)}
              type="button"
            >
              +
            </button>
            {workspacePickerOpen ? (
              <div className="absolute right-0 z-20 mt-2 w-80 overflow-hidden rounded border border-gray-700 bg-gray-900 py-1 shadow-xl" role="menu">
                {workspaces.map((workspace) => (
                  <button
                    className="block w-full px-3 py-2 text-left text-sm text-gray-100 hover:bg-gray-800 disabled:opacity-50"
                    disabled={createMutation.isPending}
                    key={`${workspace.kind}-${workspace.id ?? "scratch"}`}
                    onClick={() => createMutation.mutate(workspace)}
                    role="menuitem"
                    type="button"
                  >
                    <span className="block truncate font-medium">{workspace.label}</span>
                    <span className="block truncate text-xs text-gray-400">{workspace.working_directory}</span>
                  </button>
                ))}
              </div>
            ) : null}
          </div>
        </div>

        {terminalEnabled && sessionsQuery.isPending ? (
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">Loading sessions...</div>
        ) : sessionsQuery.isError ? (
          <div className="flex flex-1 items-center justify-center text-sm text-red-300">Unable to load terminal sessions.</div>
        ) : activeSession ? (
          <TerminalPane key={activeSession.id} session={activeSession} />
        ) : (
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">No terminal sessions</div>
        )}
      </div>
    </main>
  )
}

export function TerminalPane({ session }: { session: TerminalSessionRecord }) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const queryClient = useQueryClient()
  const [connected, setConnected] = useState(true)
  const [ended, setEnded] = useState(false)
  const elapsed = useElapsedTime(session.started_at)
  const killMutation = useMutation({
    mutationFn: () => killTerminalSession(session.id),
    onSuccess(payload) {
      queryClient.setQueryData(terminalSessionsQueryKey, (current: TerminalSessionsPayload | undefined) => {
        if (!current) return current
        return {
          ...current,
          sessions: current.sessions.filter((item) => item.id !== payload.session.id)
        }
      })
    }
  })

  useEffect(() => {
    if (!containerRef.current) return

    const terminal = new Terminal({
      convertEol: true,
      theme: {
        background: "#111827",
        foreground: "#e5e7eb",
        cursor: "#bfdbfe",
        selectionBackground: "#374151"
      }
    })
    const fitAddon = new FitAddon()
    terminal.loadAddon(fitAddon)
    terminal.open(containerRef.current)
    const serializeAddon = new SerializeAddon()
    terminal.loadAddon(serializeAddon)

    const snapshot = terminalSnapshots.get(session.id)
    if (snapshot) terminal.write(snapshot)

    let fitFrame: number | null = null
    let fitAttempts = 0
    const scheduleFit = () => {
      if (fitFrame !== null) return

      fitFrame = window.requestAnimationFrame(() => {
        fitFrame = null

        const rect = containerRef.current?.getBoundingClientRect()
        if (rect && rect.width > 0 && rect.height > 0) {
          fitAttempts = 0
          fitAddon.fit()
        } else if (fitAttempts < 10) {
          fitAttempts += 1
          scheduleFit()
        }
      })
    }
    scheduleFit()

    const subscription: Subscription = createConsumer().subscriptions.create(
      { channel: "TerminalChannel", session_id: session.id },
      {
        received(data: { type?: string; data?: string }) {
          if (data.type === "output" && data.data) {
            terminal.write(Uint8Array.from(atob(data.data), (character) => character.charCodeAt(0)))
          } else if (data.type === "disconnected") {
            setConnected(false)
            setEnded(true)
          }
        }
      }
    )

    const inputDisposable = terminal.onData((data) => {
      subscription.perform("receive", { type: "input", data })
    })
    const resizeDisposable = terminal.onResize(({ cols, rows }) => {
      subscription.perform("receive", { type: "resize", cols, rows })
    })
    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) => {
            for (const entry of entries) {
              if (entry.contentRect.width > 0 && entry.contentRect.height > 0) scheduleFit()
            }
          })
    resizeObserver?.observe(containerRef.current)

    return () => {
      terminalSnapshots.set(session.id, serializeAddon.serialize())
      if (fitFrame !== null) window.cancelAnimationFrame(fitFrame)
      resizeObserver?.disconnect()
      inputDisposable.dispose()
      resizeDisposable.dispose()
      subscription.unsubscribe()
      terminal.dispose()
    }
  }, [session.id])

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div className="min-h-0 flex-1 overflow-hidden bg-gray-900 p-2" ref={containerRef} />
      {ended ? (
        <div className="absolute inset-0 flex items-center justify-center bg-gray-950/60 text-sm text-gray-300">
          Session ended - reload to reconnect
        </div>
      ) : null}
      <div className="flex shrink-0 items-center gap-3 border-t border-gray-800 bg-gray-900 px-3 py-2 text-xs text-gray-300">
        <span className={connected ? "text-emerald-300" : "text-gray-500"}>{connected ? "● connected" : "○ disconnected"}</span>
        <span className="min-w-0 flex-1 truncate font-mono">{session.working_directory}</span>
        <span>{elapsed}</span>
        <button
          className="rounded border border-red-500 px-2 py-1 font-medium text-red-200 hover:bg-red-950 disabled:opacity-50"
          disabled={killMutation.isPending}
          onClick={() => killMutation.mutate()}
          type="button"
        >
          Kill
        </button>
      </div>
    </div>
  )
}

function useElapsedTime(startedAt: string) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [])

  return useMemo(() => {
    const seconds = Math.max(0, Math.floor((now - new Date(startedAt).getTime()) / 1000))
    const minutes = Math.floor(seconds / 60)
    const hours = Math.floor(minutes / 60)
    if (hours > 0) return `${hours}h ${minutes % 60}m`
    if (minutes > 0) return `${minutes}m ${seconds % 60}s`
    return `${seconds}s`
  }, [now, startedAt])
}
