import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { DragEvent, FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import { StatusPill } from "../components/StatusPill"
import { FilterBar, filterTreeFromPayload, smartFolderFiltersFromTree, topFilterChildren } from "../components/FilterBar"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { bulkDashboardJobs, createDashboardSmartFolder, fetchDashboard, toggleDashboardLandingPause, updateDashboardEpicState, updateDashboardPreferences, type DashboardBulkJobAction, type DashboardEpicItem, type DashboardItem, type DashboardJobItem, type DashboardLane, type DashboardPayload, type DashboardSmartFolder, type DashboardSubject, type DashboardWorkflowItem } from "../api/dashboard"

const KANBAN_CARDS_PER_PAGE = 20

export function DashboardRoute() {
  const location = useLocation()
  const search = dashboardApiSearch(location.pathname, location.search)
  const dashboard = useQuery({
    queryKey: ["dashboard", search],
    queryFn: () => fetchDashboard(search),
    placeholderData: (previousData) => previousData
  })

  if (dashboard.isPending) return <main aria-label="Dashboard" className="p-6 text-sm text-gray-600">Loading...</main>
  if (dashboard.isError) return <DashboardError error={dashboard.error} />

  return <DashboardView pathname={location.pathname} search={location.search} payload={dashboard.data} />
}

function DashboardView({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  const prefix = pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  return (
    <main aria-label="Dashboard" className="mx-auto max-w-[96rem] space-y-5 p-6">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-3xl font-semibold text-gray-900">Dashboard</h1>
        <DashboardCreateActions payload={payload} prefix={prefix} />
      </header>

      {isDesktop ? (
        <>
          <DesktopDashboardControls pathname={pathname} payload={payload} prefix={prefix} search={search} />
          <div className="grid gap-5 lg:grid-cols-[16rem_minmax(0,1fr)]">
            <SmartFolderNav payload={payload} prefix={prefix} search={search} />
            <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
          </div>
        </>
      ) : (
        <>
          <MobileDashboardControls pathname={pathname} payload={payload} prefix={prefix} search={search} />
          <DashboardContent pathname={pathname} payload={payload} prefix={prefix} search={search} />
        </>
      )}
    </main>
  )
}

function DesktopDashboardControls({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  return (
    <div className="grid gap-5 lg:grid-cols-[16rem_minmax(0,1fr)] lg:items-center">
      <SubjectTabs payload={payload} prefix={prefix} />
      <div className="flex min-w-0 flex-col gap-3 lg:flex-row lg:items-center">
        <div className="min-w-0 flex-1">
          <DashboardFilterBar pathname={pathname} search={search} payload={payload} />
        </div>
        <DashboardToolbar pathname={pathname} search={search} payload={payload} />
      </div>
    </div>
  )
}

function MobileDashboardControls({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  return (
    <div className="space-y-3">
      <div aria-label="Dashboard controls" className="flex items-center justify-between gap-3 pb-1" role="group">
        <div className="min-w-0 flex-1 overflow-x-auto">
          <SubjectTabs className="inline-flex w-max flex-nowrap overflow-hidden rounded border border-gray-300 bg-white text-sm" payload={payload} prefix={prefix} />
        </div>
        <DashboardToolbar pathname={pathname} search={search} payload={payload} showConfiguration={false} />
      </div>
      <details className="group rounded border border-gray-200 bg-white">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium text-gray-700">
          <span>Folders and filters</span>
          <span className="text-gray-400 group-open:hidden">Show</span>
          <span className="hidden text-gray-400 group-open:inline">Hide</span>
        </summary>
        <div className="space-y-4 border-t border-gray-200 p-4">
          <DashboardFilterBar pathname={pathname} search={search} payload={payload} />
          <SmartFolderNav payload={payload} prefix={prefix} search={search} />
        </div>
      </details>
    </div>
  )
}

function DashboardContent({ payload, pathname, prefix, search }: { payload: DashboardPayload; pathname: string; prefix: string; search: string }) {
  return (
    <section className="min-w-0 space-y-4">
      <DashboardTable payload={payload} prefix={prefix} />
      {payload.view === "list" ? <Pagination pathname={pathname} search={search} payload={payload} /> : null}
    </section>
  )
}

function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}

function DashboardCreateActions({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  return (
    <div className="flex flex-wrap gap-2">
      <Link className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(payload.paths.new_epic_path, prefix)}>New Epic</Link>
      <Link className="rounded bg-green-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-green-500" to={withRoutePrefix(payload.paths.new_job_path, prefix)}>New Job</Link>
    </div>
  )
}

function SubjectTabs({ payload, prefix, className = "inline-flex overflow-hidden rounded border border-gray-300 bg-white text-sm" }: { payload: DashboardPayload; prefix: string; className?: string }) {
  const subjects: Array<{ key: DashboardSubject; label: string; path: string }> = [
    { key: "epic", label: "Epics", path: "/dashboard/epics" },
    { key: "job", label: "Jobs", path: "/dashboard/jobs" },
    { key: "workflow", label: "Workflows", path: "/dashboard/workflows" }
  ]

  return (
    <nav aria-label="Dashboard subjects" className={className}>
      {subjects.map((subject) => (
        <Link
          className={`px-3 py-1.5 font-medium ${payload.subject === subject.key ? "bg-blue-50 text-blue-700 ring-1 ring-inset ring-blue-600" : "text-gray-700 hover:bg-gray-50"}`}
          key={subject.key}
          to={dashboardLink(`${prefix}${subject.path}`, { view: payload.view })}
        >
          {subject.label}
        </Link>
      ))}
    </nav>
  )
}

function SmartFolderNav({ payload, prefix, search }: { payload: DashboardPayload; prefix: string; search: string }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = payload.smart_folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = payload.smart_folders.filter((folder) => folder.kind === "user_defined")
  const appliedTree = filterTreeFromPayload(payload.filter)
  const canSaveFilter = topFilterChildren(appliedTree).length > 0 && payload.active_smart_folder_id == null
  const landingPause = useMutation({
    mutationFn: () => toggleDashboardLandingPause(payload.landing_queue.toggle_path),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const createFolder = useMutation({
    mutationFn: () => createDashboardSmartFolder({
      subject: payload.subject,
      name: folderName,
      filters: smartFolderFiltersFromTree(appliedTree)
    }),
    onSuccess: (created) => {
      setFolderName("")
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
      navigate(withRoutePrefix(created.redirect_to, prefix))
    }
  })

  function saveFolder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    createFolder.mutate()
  }

  return (
    <aside aria-label="Dashboard smart folders panel" className="space-y-2">
      <h2 className="text-xs font-semibold uppercase text-gray-500">Smart folders</h2>
      <nav aria-label="Dashboard smart folders" className="space-y-1">
        <Link className={folderClass(payload.active_smart_folder_id == null)} to={dashboardLink(`${prefix}${subjectPath(payload.subject)}`, { view: payload.view })}>
          All {subjectLabel(payload.subject, 2)}
        </Link>
        {primaryFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
        {moreFolders.length > 0 ? (
          <details className="space-y-1" open={moreFolders.some((folder) => folder.active) || undefined}>
            <summary className="cursor-pointer rounded px-2 py-1.5 text-sm font-medium text-gray-600 hover:bg-gray-100">More</summary>
            <div className="space-y-1 pl-2">
              {moreFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
            </div>
          </details>
        ) : null}
      </nav>
      <div className="space-y-1 pt-3">
        <div className="flex items-center justify-between gap-2 px-2">
          <h3 className="text-xs font-semibold uppercase text-gray-500">Saved</h3>
          <Link className="text-xs font-medium text-blue-700 hover:text-blue-900" to={withRoutePrefix(`/smart_folders?subject_type=${payload.subject}`, prefix)}>Manage</Link>
        </div>
        {savedFolders.length > 0 ? (
          <nav aria-label="Saved smart folders" className="space-y-1">
            {savedFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400">No saved folders</p>
        )}
      </div>
      {canSaveFilter ? (
        <form className="space-y-2 px-2 pt-3" onSubmit={saveFolder}>
          <label className="block text-xs font-medium uppercase text-gray-500" htmlFor="dashboard-smart-folder-name">
            Folder name
            <input
              className="mt-1 block w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700"
              disabled={createFolder.isPending}
              id="dashboard-smart-folder-name"
              maxLength={120}
              onChange={(event) => setFolderName(event.target.value)}
              required
              type="text"
              value={folderName}
            />
          </label>
          <button className="w-full rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-gray-300" disabled={createFolder.isPending} type="submit">
            Save folder
          </button>
          {createFolder.isError ? <p className="text-xs text-red-700" role="alert">{errorMessage(createFolder.error, "Unable to save smart folder.")}</p> : null}
        </form>
      ) : null}
      {payload.landing_queue.visible ? (
        <div className="space-y-2 rounded border border-gray-200 bg-white p-2">
          <button
            className="w-full rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300"
            disabled={landingPause.isPending}
            onClick={() => landingPause.mutate()}
            type="button"
          >
            {payload.landing_queue.paused ? "Resume landing" : "Pause landing"}
          </button>
          <NoticeToast message={landingPause.isSuccess ? landingPause.data.message : null} onDismiss={() => landingPause.reset()} />
          {landingPause.isError ? <p className="text-xs text-red-700" role="alert">{errorMessage(landingPause.error, "Unable to update landing queue.")}</p> : null}
        </div>
      ) : null}
    </aside>
  )
}

function SmartFolderLink({ folder, prefix }: { folder: DashboardSmartFolder; prefix: string }) {
  return (
    <Link aria-label={`${folder.name} ${folder.count}`} className={folderClass(folder.active)} to={withRoutePrefix(folder.path, prefix)}>
      <span className="truncate">{folder.name}</span>
      <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${folder.active ? "bg-blue-100 text-blue-700" : "bg-gray-100 text-gray-600"}`}>{folder.count}</span>
    </Link>
  )
}

function DashboardToolbar({ payload, pathname, search, showConfiguration = true }: { payload: DashboardPayload; pathname: string; search: string; showConfiguration?: boolean }) {
  const queryClient = useQueryClient()
  const [columnsOpen, setColumnsOpen] = useState(false)
  const [lanesOpen, setLanesOpen] = useState(false)
  const columnsMenuRef = useDismissiblePopup<HTMLDivElement>(columnsOpen, () => setColumnsOpen(false))
  const lanesMenuRef = useDismissiblePopup<HTMLDivElement>(lanesOpen, () => setLanesOpen(false))
  const updatePreferences = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  function updateLane(lane: string, checked: boolean) {
    const current = payload.preferences.kanban_lanes
    const next = checked ? [ ...current, lane ].filter(uniqueValue) : current.filter((value) => value !== lane)
    updatePreferences.mutate({
      subject: payload.subject,
      kanban_lanes: next
    })
  }

  function updateColumn(column: string, checked: boolean) {
    const optionalColumns = payload.controls.columns.optional.map((option) => option.key)
    const next = optionalColumns.filter((candidate) => {
      if (candidate === column) return checked
      return payload.preferences.visible_columns.includes(candidate)
    })
    updatePreferences.mutate({
      subject: payload.subject,
      visible_columns: next
    })
  }

  return (
    <div className="shrink-0">
      <div className="flex flex-wrap items-center justify-end gap-3">
        <nav aria-label="Dashboard view" className="inline-flex overflow-hidden rounded border border-gray-300 bg-white text-sm">
          {payload.controls.views.map((view) => (
            <Link
              className={`px-3 py-1.5 capitalize ${payload.view === view ? "bg-gray-900 text-white" : "text-gray-700 hover:bg-gray-50"}`}
              key={view}
              to={dashboardLinkFromSearch(pathname, search, { view, page: null })}
            >
              {view}
            </Link>
          ))}
        </nav>
        {showConfiguration && payload.view === "list" ? (
          <div className="relative" ref={columnsMenuRef}>
            <button
              aria-label="Columns"
              aria-controls="dashboard-columns-menu"
              aria-expanded={columnsOpen}
              aria-haspopup="menu"
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-300 bg-white text-gray-700 hover:bg-gray-50"
              onClick={() => setColumnsOpen((open) => !open)}
              type="button"
            >
              <ColumnsIcon />
            </button>
            {columnsOpen ? (
              <div className="absolute right-0 z-20 mt-2 w-64 rounded border border-gray-200 bg-white p-3 shadow-lg" id="dashboard-columns-menu" role="menu">
                <fieldset className="space-y-2">
                  <legend className="text-xs font-semibold uppercase text-gray-500">Visible columns</legend>
                  {payload.controls.columns.optional.map((column) => (
                    <label className="flex items-center gap-2 text-sm text-gray-700" key={column.key}>
                      <input
                        checked={payload.preferences.visible_columns.includes(column.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateColumn(column.key, event.target.checked)}
                        type="checkbox"
                      />
                      <span>{column.title}</span>
                    </label>
                  ))}
                </fieldset>
              </div>
            ) : null}
          </div>
        ) : null}
        {showConfiguration && payload.view === "kanban" ? (
          <div className="relative" ref={lanesMenuRef}>
            <button
              aria-label="Kanban lanes"
              aria-controls="dashboard-kanban-lanes-menu"
              aria-expanded={lanesOpen}
              aria-haspopup="menu"
              className="inline-flex h-9 w-9 items-center justify-center rounded border border-gray-300 bg-white text-gray-700 hover:bg-gray-50"
              onClick={() => setLanesOpen((open) => !open)}
              type="button"
            >
              <ColumnsIcon />
            </button>
            {lanesOpen ? (
              <div className="absolute right-0 z-20 mt-2 w-64 rounded border border-gray-200 bg-white p-3 shadow-lg" id="dashboard-kanban-lanes-menu" role="menu">
                <fieldset className="space-y-2">
                  <legend className="text-xs font-semibold uppercase text-gray-500">Kanban lanes</legend>
                  {payload.controls.kanban_lanes.map((lane) => (
                    <label className="flex items-center gap-2 text-sm text-gray-700" key={lane.key}>
                      <input
                        checked={payload.preferences.kanban_lanes.includes(lane.key)}
                        disabled={updatePreferences.isPending}
                        onChange={(event) => updateLane(lane.key, event.target.checked)}
                        type="checkbox"
                      />
                      <span>{lane.title}</span>
                    </label>
                  ))}
                </fieldset>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
      {updatePreferences.isError ? <p className="mt-1 text-right text-sm text-red-700" role="alert">{errorMessage(updatePreferences.error, "Unable to update dashboard preferences.")}</p> : null}
    </div>
  )
}

function ColumnsIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M7 4v16M17 4v16M5 5h14M5 12h14M5 19h14" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" />
    </svg>
  )
}

function DashboardFilterBar({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  return (
    <FilterBar
      buildLink={dashboardLinkFromSearch}
      filter={payload.filter}
      filterSchema={payload.controls.filter_schema}
      legacyFilterKeys={legacyFilterKeys}
      pathname={pathname}
      search={search}
    />
  )
}

const legacyFilterKeys = ["state", "repository_id", "kind", "trigger_kind", "job_id", "attention", "tag_ids", "pr", "age"]

function DashboardTable({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  const queryClient = useQueryClient()
  const updateSort = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const sortState: DashboardSortState = {
    column: sortValue(payload.preferences.sort, "column") || payload.controls.sort_columns[0] || "title",
    direction: sortValue(payload.preferences.sort, "direction") || "desc",
    pending: updateSort.isPending,
    sortableColumns: payload.controls.sort_columns,
    onSort: (column) => {
      const sortColumn = sortableColumnFor(payload.subject, column)
      if (!sortColumn || !payload.controls.sort_columns.includes(sortColumn)) return

      const currentColumn = sortValue(payload.preferences.sort, "column") || payload.controls.sort_columns[0] || "title"
      const currentDirection = sortValue(payload.preferences.sort, "direction") || "desc"
      const nextDirection = currentColumn === sortColumn && currentDirection === "asc" ? "desc" : "asc"
      updateSort.mutate({
        subject: payload.subject,
        sort_column: sortColumn,
        sort_direction: nextDirection
      })
    }
  }

  if (payload.view === "kanban") return <DashboardKanban payload={payload} prefix={prefix} />

  if (payload.items.length === 0) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500">No {subjectLabel(payload.subject, 2)} match this view.</div>
  }

  const columns = dashboardVisibleColumns(payload)
  if (payload.subject === "job") return <JobsDashboardTable columns={columns} items={payload.items.filter((item): item is DashboardJobItem => item.type === "job")} prefix={prefix} sortState={sortState} />
  if (payload.subject === "workflow") return <WorkflowsTable columns={columns} items={payload.items.filter((item): item is DashboardWorkflowItem => item.type === "workflow")} prefix={prefix} sortState={sortState} />

  return <EpicsTable columns={columns} items={payload.items.filter((item): item is DashboardEpicItem => item.type === "epic")} prefix={prefix} sortState={sortState} />
}

function DashboardKanban({ payload, prefix }: { payload: DashboardPayload; prefix: string }) {
  const queryClient = useQueryClient()
  const [draggedEpic, setDraggedEpic] = useState<DashboardEpicItem | null>(null)
  const [dragOverLane, setDragOverLane] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const moveEpic = useMutation({
    mutationFn: ({ epic, targetState }: { epic: DashboardEpicItem; targetState: string }) => updateDashboardEpicState(epic.paths.app_state_path, targetState),
    onSuccess: (updated) => {
      setNotice(updated.message || "Epic updated.")
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  if (payload.lanes.length === 0) {
    return <div className="rounded border border-gray-200 bg-white p-6 text-sm text-gray-500">No kanban lanes are configured.</div>
  }

  function startDrag(epic: DashboardEpicItem, event: DragEvent<HTMLElement>) {
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", String(epic.id))
    setDraggedEpic(epic)
    setNotice(null)
  }

  function clearDrag() {
    setDraggedEpic(null)
    setDragOverLane(null)
  }

  function dragOverLaneFor(lane: DashboardLane, event: DragEvent<HTMLElement>) {
    if (!draggedEpic || moveEpic.isPending) return
    if (!canMoveEpicToLane(draggedEpic, lane.key)) {
      setDragOverLane(null)
      return
    }

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    setDragOverLane(lane.key)
  }

  function dropOnLane(lane: DashboardLane, event: DragEvent<HTMLElement>) {
    if (!draggedEpic || !canMoveEpicToLane(draggedEpic, lane.key) || moveEpic.isPending) {
      clearDrag()
      return
    }

    event.preventDefault()
    moveEpic.mutate({ epic: draggedEpic, targetState: lane.key })
    clearDrag()
  }

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {moveEpic.isError ? <div className="rounded border border-red-200 bg-red-50 p-3 text-sm text-red-700" role="alert">{errorMessage(moveEpic.error, "Unable to move Epic.")}</div> : null}
      <div className="overflow-x-auto pb-2">
        <div className="grid min-w-[56rem] gap-3" style={{ gridTemplateColumns: `repeat(${payload.lanes.length}, minmax(14rem, 1fr))` }}>
          {payload.lanes.map((lane) => (
            <KanbanLane
              draggingOver={dragOverLane === lane.key}
              key={lane.key}
              lane={lane}
              onDragEnd={clearDrag}
              onDragOver={(event) => dragOverLaneFor(lane, event)}
              onDragStart={startDrag}
              onDrop={(event) => dropOnLane(lane, event)}
              prefix={prefix}
              subject={payload.subject}
            />
          ))}
        </div>
      </div>
    </>
  )
}

function KanbanLane({
  draggingOver,
  lane,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  prefix,
  subject
}: {
  draggingOver: boolean
  lane: DashboardLane
  onDragEnd: () => void
  onDragOver: (event: DragEvent<HTMLElement>) => void
  onDragStart: (epic: DashboardEpicItem, event: DragEvent<HTMLElement>) => void
  onDrop: (event: DragEvent<HTMLElement>) => void
  prefix: string
  subject: DashboardSubject
}) {
  const itemSignature = lane.items.map((item) => `${item.type}-${item.id}`).join(",")
  const [visibleCount, setVisibleCount] = useState(KANBAN_CARDS_PER_PAGE)
  const visibleItems = lane.items.slice(0, visibleCount)
  const hiddenCount = lane.items.length - visibleItems.length

  useEffect(() => {
    setVisibleCount(KANBAN_CARDS_PER_PAGE)
  }, [lane.key, itemSignature])

  return (
    <section
      aria-label={`${lane.title} lane`}
      className={`min-h-64 rounded border bg-gray-50 ${draggingOver ? "border-blue-400 ring-2 ring-blue-100" : "border-gray-200"}`}
      onDragOver={onDragOver}
      onDrop={onDrop}
    >
      <header className="flex items-center justify-between border-b border-gray-200 px-3 py-2">
        <h3 className="text-sm font-semibold text-gray-900">{lane.title}</h3>
        <span className="rounded bg-white px-2 py-0.5 text-xs text-gray-500 ring-1 ring-gray-200">{lane.count}</span>
      </header>
      <div className="space-y-2 p-2">
        {lane.items.length === 0 ? <p className="px-1 py-2 text-sm text-gray-400">No {subjectLabel(subject, 2)}</p> : null}
        {visibleItems.map((item) => (
          <KanbanCard
            item={item}
            key={`${item.type}-${item.id}`}
            onDragEnd={onDragEnd}
            onDragStart={onDragStart}
            prefix={prefix}
          />
        ))}
        {hiddenCount > 0 ? (
          <button
            aria-label={`Load more ${lane.title}`}
            className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
            onClick={() => setVisibleCount((count) => count + KANBAN_CARDS_PER_PAGE)}
            type="button"
          >
            Load more
          </button>
        ) : null}
      </div>
    </section>
  )
}

function KanbanCard({ item, onDragEnd, onDragStart, prefix }: { item: DashboardItem; onDragEnd: () => void; onDragStart: (epic: DashboardEpicItem, event: DragEvent<HTMLElement>) => void; prefix: string }) {
  if (item.type === "job") {
    return (
      <article className="rounded border border-gray-200 bg-white p-3 shadow-sm">
        <Link className="text-sm font-medium text-blue-600 hover:underline" to={withRoutePrefix(item.paths.job_path, prefix)}>{item.title}</Link>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500">
          <StatusPill state={item.summary_state} />
          <span className="rounded bg-gray-100 px-1.5 py-0.5">{item.repository.slug}</span>
          {item.pr_number ? <ExternalMetadataLink className="rounded bg-gray-100 px-1.5 py-0.5 text-gray-500 hover:text-blue-700 hover:underline" href={item.pr_url}>PR #{item.pr_number}</ExternalMetadataLink> : null}
        </div>
      </article>
    )
  }

  if (item.type === "workflow") {
    return (
      <article className="rounded border border-gray-200 bg-white p-3 shadow-sm">
        <div className="text-sm font-medium text-gray-900">Workflow #{item.id}</div>
        <Link className="mt-1 block text-sm text-blue-600 hover:underline" to={withRoutePrefix(item.job.path, prefix)}>{item.job.title}</Link>
        <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500">
          <StatusPill state={item.state} />
          <span className="rounded bg-gray-100 px-1.5 py-0.5">{item.trigger_kind}</span>
        </div>
      </article>
    )
  }

  return (
    <article
      aria-label={`${item.display_number} ${item.title}`}
      className="cursor-grab rounded border border-gray-200 bg-white p-3 shadow-sm active:cursor-grabbing"
      draggable
      onDragEnd={onDragEnd}
      onDragStart={(event) => onDragStart(item, event)}
    >
      <Link className="text-sm font-medium text-blue-600 hover:underline" to={withRoutePrefix(item.paths.epic_path, prefix)}>{item.title}</Link>
      <div className="mt-2 flex flex-wrap gap-1 text-xs text-gray-500">
        <NeutralStatePill state={item.state} />
        <span className="rounded bg-gray-100 px-1.5 py-0.5">{item.repository.slug}</span>
      </div>
    </article>
  )
}

function canMoveEpicToLane(epic: DashboardEpicItem, targetState: string) {
  if (targetState === epic.state) return false
  if (epic.state === "ready" && targetState === "backlog") return true
  if (epic.state === "ready" && targetState === "in_progress") return true
  if (epic.state === "in_progress" && targetState === "ready") return true
  if (epic.state === "backlog" && targetState === "ready") return epic.jobs_count > 0
  return false
}

type DashboardSortState = {
  column: string
  direction: string
  pending: boolean
  sortableColumns: string[]
  onSort: (column: string) => void
}

function JobsDashboardTable({ items, columns, prefix, sortState }: { items: DashboardJobItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
  const [selectedIds, setSelectedIds] = useState<Set<number>>(() => new Set())
  const visibleIds = useMemo(() => items.map((item) => item.id), [items])
  const selectedArray = useMemo(() => Array.from(selectedIds), [selectedIds])
  const allSelected = visibleIds.length > 0 && visibleIds.every((id) => selectedIds.has(id))

  useEffect(() => {
    setSelectedIds((current) => {
      const visible = new Set(visibleIds)
      const next = new Set(Array.from(current).filter((id) => visible.has(id)))
      return next.size === current.size ? current : next
    })
  }, [visibleIds])

  function toggleAll() {
    setSelectedIds((current) => {
      if (allSelected) return new Set()
      return new Set([ ...Array.from(current), ...visibleIds ])
    })
  }

  function toggleOne(id: number) {
    setSelectedIds((current) => {
      const next = new Set(current)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div className="space-y-3">
      <BulkJobActions selectedIds={selectedArray} onClear={() => setSelectedIds(new Set())} />
      <JobsTable
        allSelected={allSelected}
        columns={columns}
        items={items}
        onToggleAll={toggleAll}
        onToggleOne={toggleOne}
        prefix={prefix}
        selectedIds={selectedIds}
        sortState={sortState}
      />
    </div>
  )
}

function BulkJobActions({ selectedIds, onClear }: { selectedIds: number[]; onClear: () => void }) {
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const action = useMutation({
    mutationFn: (bulkAction: DashboardBulkJobAction) => bulkDashboardJobs({ job_ids: selectedIds, bulk_action: bulkAction }),
    onSuccess: (payload) => {
      setNotice(payload.message)
      onClear()
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const disabled = selectedIds.length === 0 || action.isPending

  function run(bulkAction: DashboardBulkJobAction) {
    setNotice(null)
    if (bulkAction === "close" && !window.confirm(`Close ${selectedIds.length} selected job${selectedIds.length === 1 ? "" : "s"}?`)) return
    action.mutate(bulkAction)
  }

  if (selectedIds.length === 0) {
    return <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
  }

  return (
    <div className="flex flex-wrap items-center justify-between gap-3 rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm">
      <div>
        <span className="font-medium text-gray-900">{selectedIds.length} selected</span>
        <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
        {action.isError ? <span className="ml-3 text-red-700" role="alert">{errorMessage(action.error, "Bulk action failed.")}</span> : null}
      </div>
      <div className="flex flex-wrap gap-2">
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("retry")} type="button">Retry</button>
        <button className={bulkButtonClass(disabled)} disabled={disabled} onClick={() => run("approve")} type="button">Approve</button>
        <button className={bulkButtonClass(disabled, "danger")} disabled={disabled} onClick={() => run("close")} type="button">Close</button>
      </div>
    </div>
  )
}

function JobsTable({
  items,
  columns,
  selectedIds,
  allSelected,
  onToggleAll,
  onToggleOne,
  prefix,
  sortState
}: {
  items: DashboardJobItem[]
  columns: string[]
  selectedIds: Set<number>
  allSelected: boolean
  onToggleAll: () => void
  onToggleOne: (id: number) => void
  prefix: string
  sortState: DashboardSortState
}) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  if (!isDesktop) return <MobileJobsList items={items} onToggleOne={onToggleOne} prefix={prefix} selectedIds={selectedIds} />

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white">
      <table className="min-w-full divide-y divide-gray-200 text-sm">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500">
          <tr>
            {columns.map((column) => (
              <th aria-sort={columnAriaSort("job", column, sortState)} className={column === "checkbox" ? "w-10 px-4 py-2" : "px-4 py-2"} key={column}>
                {column === "checkbox" ? <input aria-label="Select all jobs" checked={allSelected} onChange={onToggleAll} type="checkbox" /> : <SortableColumnHeader column={column} sortState={sortState} subject="job" />}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {items.map((job) => (
            <tr key={job.id}>
              {columns.map((column) => <JobCell column={column} job={job} key={column} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} />)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function MobileJobsList({ items, selectedIds, onToggleOne, prefix }: { items: DashboardJobItem[]; selectedIds: Set<number>; onToggleOne: (id: number) => void; prefix: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white">
      <div className="divide-y divide-gray-100">
        {items.map((job) => <MobileJobRow job={job} key={job.id} onToggleOne={onToggleOne} prefix={prefix} selected={selectedIds.has(job.id)} />)}
      </div>
    </div>
  )
}

function MobileJobRow({ job, selected, onToggleOne, prefix }: { job: DashboardJobItem; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  const approvalLabel = job.approved_at ? "Approved" : "Not approved"

  return (
    <article aria-label={job.title} className="grid grid-cols-[auto_minmax(0,1fr)] gap-3 px-4 py-3">
      <input aria-label={`Select ${job.title}`} checked={selected} className="mt-1" onChange={() => onToggleOne(job.id)} type="checkbox" />
      <div className="min-w-0 text-gray-700">
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <StatusPill state={job.summary_state} />
          <span className="text-xs font-medium text-gray-500">{formatCurrency(job.total_cost_usd, 2)}</span>
          <span className="font-mono text-xs text-gray-500">{job.repository.slug}</span>
        </div>
        <div className="mt-1 flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <Link aria-label={job.title} className="rounded-sm text-sm font-semibold leading-snug text-blue-600 underline focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500" to={withRoutePrefix(job.paths.job_path, prefix)}>{job.title}</Link>
          {job.kind !== "issue" ? <span className="text-xs text-gray-500">{humanizeOption(job.kind)}</span> : null}
        </div>
        <div className="mt-1 flex flex-wrap gap-x-2 gap-y-1 text-xs text-gray-500">
          <IssueMetadata job={job} />
          {job.pr_number ? <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink> : null}
          <span>{approvalLabel}</span>
          <span>{job.workflows_count} {pluralize(job.workflows_count, "workflow")}</span>
          <span>{formatDate(job.started_at || job.created_at)}</span>
        </div>
        {job.tags.length > 0 ? (
          <div className="mt-1 flex flex-wrap gap-1">
            {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5 text-xs text-gray-500" key={tag.id}>{tag.name}</span>)}
          </div>
        ) : null}
      </div>
    </article>
  )
}

function JobCell({ job, column, selected, onToggleOne, prefix }: { job: DashboardJobItem; column: string; selected: boolean; onToggleOne: (id: number) => void; prefix: string }) {
  if (column === "checkbox") {
    return <td className="px-4 py-3 align-top"><input aria-label={`Select ${job.title}`} checked={selected} onChange={() => onToggleOne(job.id)} type="checkbox" /></td>
  }
  if (column === "issue" || column === "title") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(job.paths.job_path, prefix)}>{job.title}</Link>
        <div className="mt-1 flex flex-wrap gap-1 text-xs text-gray-500">
          <IssueMetadata job={job} />
          {job.pr_number ? <ExternalMetadataLink href={job.pr_url}>PR #{job.pr_number}</ExternalMetadataLink> : null}
          {job.tags.map((tag) => <span className="rounded bg-gray-100 px-1.5 py-0.5" key={tag.id}>{tag.name}</span>)}
        </div>
      </td>
    )
  }
  if (column === "state") return <td className="px-4 py-3"><StatusPill state={job.summary_state} /></td>
  if (column === "repository") return <td className="px-4 py-3 font-mono text-xs text-gray-600">{job.repository.slug}</td>
  if (column === "latest") return <LatestWorkflowCell job={job} />
  if (column === "workflows_count") return <td className="px-4 py-3 text-gray-700">{job.workflows_count}</td>

  return <td className="px-4 py-3 text-gray-500">{formatDate(jobDateValue(job, column))}</td>
}

function LatestWorkflowCell({ job }: { job: DashboardJobItem }) {
  if (!job.latest_workflow_trigger_kind) {
    return <td className="px-4 py-3"><StatusPill state={job.latest_workflow_state} /></td>
  }

  return (
    <td aria-label={`Latest workflow: ${job.latest_workflow_trigger_kind} ${job.latest_workflow_state}`} className="px-4 py-3">
      <div className="flex flex-col items-start gap-1">
        <span className="text-xs text-gray-500">{job.latest_workflow_trigger_kind}</span>
        <StatusPill state={job.latest_workflow_state} />
      </div>
    </td>
  )
}

function IssueMetadata({ job }: { job: DashboardJobItem }) {
  const label = `#${job.issue_number || job.id}`

  if (!job.issue_number) return <span>{label}</span>

  return <ExternalMetadataLink href={job.issue_url}>{label}</ExternalMetadataLink>
}

function ExternalMetadataLink({ children, className = "text-gray-500 hover:text-blue-700 hover:underline", href }: { children: ReactNode; className?: string; href: string | null }) {
  if (!href) return <span className={className}>{children}</span>

  return <a className={className} href={href} rel="noopener noreferrer" target="_blank">{children}</a>
}

function EpicsTable({ items, columns, prefix, sortState }: { items: DashboardEpicItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  if (!isDesktop) return <MobileEpicsList items={items} prefix={prefix} />

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white">
      <table className="min-w-full divide-y divide-gray-200 text-sm">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500">
          <tr>
            {columns.map((column) => <th aria-sort={columnAriaSort("epic", column, sortState)} className="px-4 py-2" key={column}><SortableColumnHeader column={column} sortState={sortState} subject="epic" /></th>)}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {items.map((epic) => (
            <tr key={epic.id}>
              {columns.map((column) => <EpicCell column={column} epic={epic} key={column} prefix={prefix} />)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function MobileEpicsList({ items, prefix }: { items: DashboardEpicItem[]; prefix: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white">
      <div className="divide-y divide-gray-100">
        {items.map((epic) => <MobileEpicRow epic={epic} key={epic.id} prefix={prefix} />)}
      </div>
    </div>
  )
}

function MobileEpicRow({ epic, prefix }: { epic: DashboardEpicItem; prefix: string }) {
  return (
    <Link aria-label={`${epic.display_number} ${epic.title}`} className="grid grid-cols-[7.25rem_minmax(0,1fr)] gap-3 px-4 py-3 text-gray-700 hover:bg-gray-50 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500" to={withRoutePrefix(epic.paths.epic_path, prefix)}>
      <div className="pt-1">
        <NeutralStatePill state={epic.state} />
      </div>
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500">{epic.display_number}</span>
          <h2 className="text-sm font-semibold leading-snug text-gray-900">{epic.title}</h2>
        </div>
        {compactText(epic.description) ? <p className="mt-1 line-clamp-2 text-sm leading-snug text-gray-500">{compactText(epic.description)}</p> : null}
        <div className="mt-1 font-mono text-xs text-gray-500">{epic.repository.slug}</div>
      </div>
    </Link>
  )
}

function EpicCell({ epic, column, prefix }: { epic: DashboardEpicItem; column: string; prefix: string }) {
  if (column === "epic") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(epic.paths.epic_path, prefix)}>{epic.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500">{epic.display_number}</div>
      </td>
    )
  }
  if (column === "state") return <td className="px-4 py-3"><NeutralStatePill state={epic.state} /></td>
  if (column === "repository") return <td className="px-4 py-3 font-mono text-xs text-gray-600">{epic.repository.slug}</td>
  if (column === "updated") return <td className="px-4 py-3 text-gray-500">{formatDate(epic.updated_at)}</td>

  return <td className="px-4 py-3 text-gray-500">{formatDate(epicDateValue(epic, column))}</td>
}

function WorkflowsTable({ items, columns, prefix, sortState }: { items: DashboardWorkflowItem[]; columns: string[]; prefix: string; sortState: DashboardSortState }) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  if (!isDesktop) return <MobileWorkflowsList items={items} prefix={prefix} />

  return (
    <div className="overflow-x-auto rounded border border-gray-200 bg-white">
      <table className="min-w-full divide-y divide-gray-200 text-sm">
        <thead className="bg-gray-50 text-left text-xs font-semibold uppercase text-gray-500">
          <tr>
            {columns.map((column) => <th aria-sort={columnAriaSort("workflow", column, sortState)} className="px-4 py-2" key={column}><SortableColumnHeader column={column} sortState={sortState} subject="workflow" /></th>)}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {items.map((workflow) => (
            <tr key={workflow.id}>
              {columns.map((column) => <WorkflowCell column={column} key={column} prefix={prefix} workflow={workflow} />)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function MobileWorkflowsList({ items, prefix }: { items: DashboardWorkflowItem[]; prefix: string }) {
  return (
    <div className="rounded border border-gray-200 bg-white">
      <div className="divide-y divide-gray-100">
        {items.map((workflow) => <MobileWorkflowRow key={workflow.id} prefix={prefix} workflow={workflow} />)}
      </div>
    </div>
  )
}

function MobileWorkflowRow({ workflow, prefix }: { prefix: string; workflow: DashboardWorkflowItem }) {
  const startedAt = workflow.started_at || workflow.created_at
  const finishedAt = workflow.finished_at || workflow.cleaned_up_at

  return (
    <Link aria-label={`Workflow #${workflow.id} ${workflow.job.title}`} className="grid grid-cols-[7.25rem_minmax(0,1fr)] gap-3 px-4 py-3 text-gray-700 hover:bg-gray-50 hover:text-gray-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500" to={withRoutePrefix(workflow.job.path, prefix)}>
      <div className="pt-1">
        <StatusPill state={workflow.state} />
      </div>
      <div className="min-w-0">
        <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
          <span className="font-mono text-xs font-semibold uppercase tracking-wide text-gray-500">Workflow #{workflow.id}</span>
          <span className="text-sm font-semibold leading-snug text-blue-600 underline">{workflow.job.title}</span>
        </div>
        <div className="mt-1 font-mono text-xs text-gray-500">{workflow.job.repository.slug}</div>
        <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-gray-500">
          <span>{workflow.trigger_kind}</span>
          <span>{workflow.agent_provider}</span>
          {startedAt ? <span>Started {formatDate(startedAt)}</span> : null}
          {finishedAt ? <span>Finished {formatDate(finishedAt)}</span> : null}
        </div>
      </div>
    </Link>
  )
}

function SortableColumnHeader({ subject, column, sortState }: { subject: DashboardSubject; column: string; sortState: DashboardSortState }) {
  const label = dashboardColumnLabel(subject, column)
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || !sortState.sortableColumns.includes(sortColumn)) return <span>{label}</span>

  const active = sortState.column === sortColumn
  const nextDirection = active && sortState.direction === "asc" ? "desc" : "asc"

  return (
    <button
      aria-label={`Sort by ${label} ${sortDirectionLabel(nextDirection).toLowerCase()}`}
      className={`inline-flex items-center gap-1 text-left font-semibold uppercase ${active ? "text-gray-900" : "text-gray-500 hover:text-gray-900"}`}
      disabled={sortState.pending}
      onClick={() => sortState.onSort(column)}
      type="button"
    >
      <span>{label}</span>
      {active ? <span aria-hidden="true" className="text-[11px] leading-none text-gray-700">{sortState.direction === "asc" ? "↑" : "↓"}</span> : null}
    </button>
  )
}

function WorkflowCell({ workflow, column, prefix }: { workflow: DashboardWorkflowItem; column: string; prefix: string }) {
  if (column === "workflow" || column === "title") return <td className="px-4 py-3 font-medium text-gray-900">Workflow #{workflow.id}</td>
  if (column === "state") return <td className="px-4 py-3"><StatusPill state={workflow.state} /></td>
  if (column === "job") {
    return (
      <td className="max-w-md px-4 py-3">
        <Link className="font-medium text-blue-600 hover:underline" to={withRoutePrefix(workflow.job.path, prefix)}>{workflow.job.title}</Link>
        <div className="mt-1 font-mono text-xs text-gray-500">{workflow.job.repository.slug}</div>
      </td>
    )
  }
  if (column === "trigger") return <td className="px-4 py-3 text-gray-700">{workflow.trigger_kind}</td>
  if (column === "agent") return <td className="px-4 py-3 text-gray-700">{workflow.agent_provider}</td>
  if (column === "started") return <td className="px-4 py-3 text-gray-500">{formatDate(workflow.started_at || workflow.created_at)}</td>
  if (column === "finished") return <td className="px-4 py-3 text-gray-500">{formatDate(workflow.finished_at)}</td>

  return <td className="px-4 py-3 text-gray-500">{formatDate(workflowDateValue(workflow, column))}</td>
}

function Pagination({ payload, pathname, search }: { payload: DashboardPayload; pathname: string; search: string }) {
  if (payload.total_pages <= 1) return null

  const firstItem = (payload.page - 1) * payload.per_page + 1
  const lastItem = Math.min(payload.page * payload.per_page, payload.total)

  return (
    <div className="flex items-center justify-between text-sm text-gray-600">
      <span>Showing {firstItem}-{lastItem} of {payload.total}</span>
      <div className="flex gap-2">
        {payload.page > 1 ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50" to={pageLink(pathname, search, payload.page - 1)}>Previous</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300">Previous</span>
        )}
        {payload.page < payload.total_pages ? (
          <Link className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50" to={pageLink(pathname, search, payload.page + 1)}>Next</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-300">Next</span>
        )}
      </div>
    </div>
  )
}

function NeutralStatePill({ state }: { state: string }) {
  return <span className="inline-flex whitespace-nowrap rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium capitalize text-gray-700 ring-1 ring-gray-200">{state.replace(/_/g, " ")}</span>
}

function compactText(value: string) {
  return value.replace(/\s+/g, " ").trim()
}

function formatCurrency(value: number, digits = 4) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits }).format(value)
}

function pluralize(count: number, singular: string) {
  return count === 1 ? singular : `${singular}s`
}

function DashboardError({ error }: { error: Error }) {
  return (
    <main aria-label="Dashboard" className="p-6">
      <p className="text-sm text-red-700">{error instanceof ApiError ? error.message : "Unable to load dashboard."}</p>
    </main>
  )
}

function dashboardApiSearch(pathname: string, search: string) {
  const params = new URLSearchParams(search)
  const subject = subjectFromPath(pathname)
  if (subject) params.set("subject", subject)

  const next = params.toString()
  return next ? `?${next}` : ""
}

function subjectFromPath(pathname: string): DashboardSubject | null {
  if (pathname.endsWith("/dashboard/jobs")) return "job"
  if (pathname.endsWith("/dashboard/workflows")) return "workflow"
  if (pathname.endsWith("/dashboard/epics")) return "epic"

  return null
}

function subjectPath(subject: DashboardSubject) {
  if (subject === "job") return "/dashboard/jobs"
  if (subject === "workflow") return "/dashboard/workflows"

  return "/dashboard/epics"
}

function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

function dashboardLinkFromSearch(path: string, search: string, updates: Record<string, string | number | null | undefined>) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function pageLink(pathname: string, search: string, page: number) {
  const params = new URLSearchParams(search)
  params.set("page", String(page))
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function folderClass(active: boolean) {
  return `flex min-w-0 items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${active ? "bg-blue-50 font-medium text-blue-700" : "text-gray-700 hover:bg-gray-100"}`
}

function bulkButtonClass(disabled: boolean, tone: "default" | "danger" = "default") {
  if (disabled) return "rounded border border-gray-200 px-3 py-1 text-gray-300"
  if (tone === "danger") return "rounded border border-red-300 px-3 py-1 text-red-700 hover:bg-red-50"

  return "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-white"
}

function uniqueValue(value: string, index: number, values: string[]) {
  return values.indexOf(value) === index
}

function subjectLabel(subject: DashboardSubject, count: number) {
  const label = subject === "job" ? "job" : subject
  return count === 1 ? label : `${label}s`
}

function sortValue(sort: Record<string, string>, key: string) {
  return sort[key]
}

function sortDirectionLabel(direction: string) {
  return direction === "asc" ? "Ascending" : "Descending"
}

function sortableColumnFor(subject: DashboardSubject, column: string) {
  const aliases: Record<DashboardSubject, Record<string, string>> = {
    epic: {
      epic: "title",
      title: "title",
      updated: "updated_at"
    },
    job: {
      issue: "title",
      title: "title",
      started: "started_at"
    },
    workflow: {
      workflow: "title",
      title: "title",
      started: "started_at",
      finished: "finished_at"
    }
  }

  return aliases[subject][column] || column
}

function columnAriaSort(subject: DashboardSubject, column: string, sortState: DashboardSortState) {
  const sortColumn = sortableColumnFor(subject, column)
  if (!sortColumn || sortState.column !== sortColumn) return undefined

  return sortState.direction === "asc" ? "ascending" : "descending"
}

function dashboardColumnLabel(subject: DashboardSubject, column: string) {
  const labels: Record<DashboardSubject, Record<string, string>> = {
    epic: {
      epic: "Epic",
      state: "State",
      repository: "Repository",
      updated: "Updated",
      created_at: "Created at",
      updated_at: "Updated at",
      done_at: "Done at",
      archived_at: "Archived at"
    },
    job: {
      checkbox: "Checkbox",
      issue: "Issue",
      title: "Title",
      state: "State",
      repository: "Repository",
      latest: "Latest",
      workflows_count: "Workflows count",
      started: "Started",
      created_at: "Created at",
      updated_at: "Updated at",
      started_at: "Started at",
      finished_at: "Finished at",
      approved_at: "Approved at",
      dependencies_overridden_at: "Dependencies overridden at",
      last_feedback_addressed_at: "Last feedback addressed at",
      last_seen_comment_at: "Last seen comment at",
      pr_mergeable_checked_at: "PR mergeable checked at"
    },
    workflow: {
      workflow: "Workflow",
      title: "Workflow",
      job: "Job",
      trigger: "Trigger",
      state: "State",
      started: "Started",
      finished: "Finished",
      agent: "Agent",
      created_at: "Created at",
      updated_at: "Updated at",
      started_at: "Started at",
      finished_at: "Finished at",
      cleaned_up_at: "Cleaned up at"
    }
  }

  return labels[subject][column] || humanizeOption(column)
}

function dashboardVisibleColumns(payload: DashboardPayload) {
  const allowed = new Set([
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.controls.columns.optional.map((column) => column.key)
  ])
  const normalized = [
    ...payload.controls.columns.required.map((column) => column.key),
    ...payload.preferences.visible_columns.map((column) => normalizeDashboardColumn(payload.subject, column))
  ]

  return normalized.filter((column, index, columns) => allowed.has(column) && columns.indexOf(column) === index)
}

function normalizeDashboardColumn(subject: DashboardSubject, column: string) {
  if (subject === "job" && column === "title") return "issue"
  if (subject === "workflow" && column === "title") return "workflow"

  return column
}

function jobDateValue(job: DashboardJobItem, column: string) {
  const values: Record<string, string | null> = {
    started: job.started_at,
    created_at: job.created_at,
    updated_at: job.updated_at,
    started_at: job.started_at,
    finished_at: job.finished_at,
    approved_at: job.approved_at,
    dependencies_overridden_at: job.dependencies_overridden_at,
    last_feedback_addressed_at: job.last_feedback_addressed_at,
    last_seen_comment_at: job.last_seen_comment_at,
    pr_mergeable_checked_at: job.pr_mergeable_checked_at
  }

  return values[column] || null
}

function epicDateValue(epic: DashboardEpicItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: epic.created_at,
    updated_at: epic.updated_at,
    done_at: epic.done_at,
    archived_at: epic.archived_at
  }

  return values[column] || null
}

function workflowDateValue(workflow: DashboardWorkflowItem, column: string) {
  const values: Record<string, string | null> = {
    created_at: workflow.created_at,
    updated_at: workflow.updated_at,
    started_at: workflow.started_at,
    finished_at: workflow.finished_at,
    cleaned_up_at: workflow.cleaned_up_at
  }

  return values[column] || null
}

function humanizeOption(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function formatDate(value: string | null) {
  if (!value) return "-"

  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}
