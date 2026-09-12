import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useMemo, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { createTerminalSession, fetchTerminalSessions, killTerminalSession, type TerminalSessionRecord, type TerminalSessionsPayload } from "../api/terminal"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { CloseIcon } from "@app/components/CloseIcon"
import { Input } from "@app/components/Input"
import { TerminalStream, type TerminalConnectionState } from "../components/TerminalStream"
import type { TerminalWorkspaceRecord } from "../api/terminal"

const terminalSessionsQueryKey = ["terminal_sessions"] as const
const pickerSections: TerminalWorkspaceRecord["section"][] = ["interesting_workflows", "coding_chats", "workers"]

export function TerminalRoute() {
  const { t } = useT("terminal")
  const { t: tCommon } = useT("common")
  usePageTitle(tCommon("page_title_terminal"))
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [activeSessionId, setActiveSessionId] = useState<number | null>(() => {
    const id = Number(new URLSearchParams(location.search).get("session"))
    return Number.isFinite(id) && id > 0 ? id : null
  })
  const [workspacePickerOpen, setWorkspacePickerOpen] = useState(false)

  const sessionsQuery = useQuery({
    queryKey: terminalSessionsQueryKey,
    queryFn: ({ signal }) => fetchTerminalSessions({ signal }),
    refetchInterval: 5000
  })

  const sessions = sessionsQuery.data?.sessions ?? []
  const workspaces = sessionsQuery.data?.workspaces ?? []
  const [workspaceSearch, setWorkspaceSearch] = useState("")
  const pickerGroups = useMemo(() => workspacePickerGroups(workspaces, workspaceSearch), [workspaces, workspaceSearch])
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
    <main aria-label={tCommon("terminal_aria")} className="flex h-screen flex-col overflow-hidden bg-gray-950 text-gray-100">
      <div className="flex min-h-0 flex-1 flex-col">
        <div className="flex shrink-0 items-center gap-2 border-b border-gray-800 bg-gray-900 px-3 py-2">
          <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto" role="tablist" aria-label={tCommon("terminal.sessions")}>
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
                  aria-label={tCommon("terminal.close_session", { name: session.name })}
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
              <div className="absolute right-0 z-20 mt-2 w-96 overflow-hidden rounded border border-gray-700 bg-gray-900 shadow-xl" role="menu">
                <div className="border-b border-gray-800 p-2">
                  <Input
                    aria-label={t("search_workspaces")}
                    autoFocus
                    className="h-9 rounded border-gray-700 bg-gray-950 py-0 text-gray-100 placeholder:text-gray-500"
                    onChange={(event) => setWorkspaceSearch(event.target.value)}
                    placeholder={t("search_workspaces_placeholder")}
                    type="search"
                    value={workspaceSearch}
                  />
                </div>
                <div className="max-h-[28rem] overflow-y-auto py-1">
                  {pickerGroups.length > 0 ? pickerGroups.map((group) => (
                    <section className="border-b border-gray-800 last:border-b-0" key={group.section}>
                      <div className="px-3 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-normal text-gray-500">{group.title}</div>
                      {group.items.map((workspace) => (
                        <button
                          className="block w-full px-3 py-2 text-left text-sm text-gray-100 hover:bg-gray-800 disabled:opacity-50"
                          disabled={createMutation.isPending || workspace.available === false}
                          key={workspace.key}
                          onClick={() => createMutation.mutate(workspace)}
                          role="menuitem"
                          title={workspace.available === false ? workspace.disabled_reason ?? undefined : undefined}
                          type="button"
                        >
                          <span className="flex min-w-0 items-center gap-2">
                            <span className="min-w-0 flex-1 truncate font-medium">{workspace.label}</span>
                            {workspace.actionability ? <span className="shrink-0 rounded border border-gray-700 px-1.5 py-0.5 text-[10px] text-gray-400">{workspace.actionability}</span> : null}
                          </span>
                          <span className="block truncate text-xs text-gray-400">{workspace.disabled_reason || workspace.secondary_text || workspace.working_directory}</span>
                          {workspace.secondary_text ? <span className="block truncate font-mono text-[11px] text-gray-500">{workspace.working_directory}</span> : null}
                        </button>
                      ))}
                    </section>
                  )) : (
                    <div className="px-3 py-8 text-center text-sm text-gray-400">{t("no_workspace_matches")}</div>
                  )}
                </div>
              </div>
            ) : null}
          </div>
        </div>

        {sessionsQuery.isPending ? (
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">{tCommon("terminal.loading")}</div>
        ) : sessionsQuery.isError ? (
          <div className="flex flex-1 items-center justify-center text-sm text-red-300">{tCommon("terminal.load_error")}</div>
        ) : activeSession ? (
          <TerminalPane key={activeSession.id} session={activeSession} />
        ) : (
          <div className="flex flex-1 items-center justify-center text-sm text-gray-400">{tCommon("terminal.empty")}</div>
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

type WorkspacePickerGroup = {
  section: TerminalWorkspaceRecord["section"]
  title: string
  items: TerminalWorkspaceRecord[]
}

function workspacePickerGroups(workspaces: TerminalWorkspaceRecord[], search: string): WorkspacePickerGroup[] {
  const query = search.trim().toLowerCase()
  const filtered = query.length > 0
    ? workspaces.filter((workspace) => workspaceSearchText(workspace).includes(query))
    : workspaces.filter((workspace) => workspace.default_visible !== false)
  const limit = query.length > 0 ? 20 : 3

  return pickerSections.flatMap((section) => {
    const items = filtered.filter((workspace) => workspace.section === section).slice(0, limit)
    if (items.length === 0) return []

    return [{
      section,
      title: items[0].section_title,
      items
    }]
  })
}

function workspaceSearchText(workspace: TerminalWorkspaceRecord) {
  return [
    workspace.search_text,
    workspace.key,
    workspace.label,
    workspace.secondary_text,
    workspace.working_directory,
    workspace.worker_hostname,
    workspace.worker_storage_key,
    workspace.queue_name
  ].filter(Boolean).join(" ").toLowerCase()
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
