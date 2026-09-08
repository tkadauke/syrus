import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "@app/api/bootstrap"
import { createTerminalSession, fetchTerminalSessions, killTerminalSession, type TerminalSessionRecord, type TerminalSessionsPayload } from "../api/terminal"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { CloseIcon } from "@app/components/CloseIcon"
import { TerminalStream, type TerminalConnectionState } from "../components/TerminalStream"

const terminalSessionsQueryKey = ["terminal_sessions"] as const

export function TerminalRoute() {
  const { t } = useT("common")
  usePageTitle(t("page_title_terminal"))
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
    <main aria-label={t("terminal_aria")} className="flex h-screen flex-col overflow-hidden bg-gray-950 text-gray-100">
      <div className="flex min-h-0 flex-1 flex-col">
        <div className="flex shrink-0 items-center gap-2 border-b border-gray-800 bg-gray-900 px-3 py-2">
          <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto" role="tablist" aria-label={t("terminal.sessions")}>
            {sessions.map((session) => (
              <div
                className={`group inline-flex h-9 min-w-0 max-w-64 items-center gap-2 rounded border px-2 text-sm ${activeSession?.id === session.id ? "border-brand bg-brand text-on-brand" : "border-gray-700 bg-gray-900 text-gray-300 hover:border-gray-600 hover:bg-gray-800"}`}
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
                  aria-label={t("terminal.close_session", { name: session.name })}
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
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-700 bg-gray-900 text-lg font-semibold text-gray-100 hover:border-brand hover:text-brand-emphasis"
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
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">{t("terminal.loading")}</div>
        ) : sessionsQuery.isError ? (
          <div className="flex flex-1 items-center justify-center text-sm text-red-300">{t("terminal.load_error")}</div>
        ) : activeSession ? (
          <TerminalPane key={activeSession.id} session={activeSession} />
        ) : (
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">{t("terminal.empty")}</div>
        )}
      </div>
    </main>
  )
}

export function TerminalPane({ session }: { session: TerminalSessionRecord }) {
  const { t } = useT("common")
  const queryClient = useQueryClient()
  const [connected, setConnected] = useState(true)
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

  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <TerminalStream
        className="relative flex min-h-0 flex-1 flex-col"
        onConnectionChange={(state: TerminalConnectionState) => setConnected(state.connected)}
        terminalSessionId={session.id}
      />
      <div className="flex shrink-0 items-center gap-3 border-t border-gray-800 bg-gray-900 px-3 py-2 text-xs text-gray-300">
        <span className={connected ? "text-emerald-300" : "text-gray-500"}>{connected ? `● ${t("terminal.connected")}` : `○ ${t("terminal.disconnected")}`}</span>
        <span className="min-w-0 flex-1 truncate font-mono">{session.working_directory}</span>
        <span>{elapsed}</span>
        <button
          className="rounded border border-red-500 px-2 py-1 font-medium text-red-200 hover:bg-red-950 disabled:opacity-50"
          disabled={killMutation.isPending}
          onClick={() => killMutation.mutate()}
          type="button"
        >
          {t("terminal.kill")}
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

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default TerminalRoute
