import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { DragEvent, FocusEvent, FormEvent, KeyboardEvent } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { createDashboardSmartFolder, toggleDashboardLandingPause, updateDashboardPreferences, type DashboardPayload, type DashboardSmartFolder, type DashboardSubject } from "../api/dashboard"
import { deleteSmartFolder, updateSmartFolder } from "../api/smartFolders"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { filterTreeFromPayload, filterTreesEqual, smartFolderFiltersFromTree, topFilterChildren, type FilterNode, type FilterTree } from "./FilterBar"
import { NoticeToast } from "./NoticeToast"

const dashboardFilterOverrideKeys = ["q", "state", "repository_id", "kind", "trigger_kind", "job_id", "attention", "tag_ids", "pr", "age"]

export function DashboardSmartFolderNav({ payload, prefix, search }: { payload: DashboardPayload; prefix: string; search: string }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = useMemo(() => payload.smart_folders.filter((folder) => folder.kind !== "user_defined"), [payload.smart_folders])
  const primaryFolders = useMemo(() => builtinFolders.filter((folder) => folder.visibility !== "on_demand"), [builtinFolders])
  const moreFolders = useMemo(() => builtinFolders.filter((folder) => folder.visibility === "on_demand"), [builtinFolders])
  const savedFolders = useMemo(() => payload.smart_folders.filter((folder) => folder.kind === "user_defined"), [payload.smart_folders])
  const activeFolder = savedFolders.find((folder) => folder.id === payload.active_smart_folder_id)
  const [orderedSavedFolders, setOrderedSavedFolders] = useState(savedFolders)
  const [isReordering, setIsReordering] = useState(false)
  const orderedSavedFoldersRef = useRef(savedFolders)
  const dragIndex = useRef<number | null>(null)
  const savedFolderPositions = useMemo(() => new Map(savedFolders.map((folder, index) => [folder.id, folder.position ?? index])), [savedFolders])
  const updatePreferences = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const allPath = dashboardLink(`${prefix}${subjectPath(payload.subject)}`, { view: payload.view, smart_folder_id: payload.subject === "job" ? "all" : null })
  const allJobsSelected = payload.subject === "job" && payload.active_smart_folder_id == null && new URLSearchParams(search).get("smart_folder_id") === "all"
  const allJobsLink = (
    <Link className={folderClass(payload.subject === "job" ? allJobsSelected : payload.active_smart_folder_id == null)} onClick={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: null })} to={allPath}>
      All {subjectLabel(payload.subject, 2)}
    </Link>
  )
  const appliedTree = filterTreeFromPayload(payload.filter)
  const hasAppliedFilter = topFilterChildren(appliedTree).length > 0
  const selectedFolder = payload.smart_folders.find((folder) => folder.id === payload.active_smart_folder_id)
  const filterChangedFromSelectedFolder = selectedFolder?.filter != null && !filterTreesEqual(appliedTree, filterTreeFromPayload(selectedFolder.filter))
  const canUpdateFilter = activeFolder != null && filterChangedFromSelectedFolder
  const canSaveFilter = selectedFolder != null && hasAppliedFilter && filterChangedFromSelectedFolder
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
  const updateFolder = useMutation({
    mutationFn: () => {
      if (!activeFolder) throw new Error("No active smart folder selected.")

      return updateSmartFolder(activeFolder.id, {
        name: activeFolder.name,
        position: activeFolder.position,
        filter: appliedTree
      })
    },
    onSuccess: () => {
      navigate(clearDashboardFilterOverrides(`${prefix}${subjectPath(payload.subject)}`, search), { replace: true })
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  useEffect(() => {
    setOrderedSavedFolders(savedFolders)
    orderedSavedFoldersRef.current = savedFolders
  }, [savedFolders])

  function saveFolder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    createFolder.mutate()
  }

  function startSavedFolderDrag(index: number, event: DragEvent<HTMLElement>) {
    dragIndex.current = index
    event.dataTransfer.effectAllowed = "move"
  }

  function dragOverSavedFolder(index: number, event: DragEvent<HTMLElement>) {
    const sourceIndex = dragIndex.current
    if (sourceIndex == null) return

    event.preventDefault()
    event.dataTransfer.dropEffect = "move"
    if (sourceIndex === index) return

    const nextFolders = reorderFolders(orderedSavedFoldersRef.current, sourceIndex, index)
    orderedSavedFoldersRef.current = nextFolders
    dragIndex.current = index
    setOrderedSavedFolders(nextFolders)
  }

  async function dropSavedFolder(event: DragEvent<HTMLElement>) {
    if (dragIndex.current == null) return

    event.preventDefault()
    const reorderedFolders = orderedSavedFoldersRef.current
    clearSavedFolderDrag()
    const changedFolders = reorderedFolders.filter((folder, index) => savedFolderPositions.get(folder.id) !== index)
    if (changedFolders.length === 0) return

    setIsReordering(true)
    try {
      await Promise.all(changedFolders.map((folder) => {
        const position = reorderedFolders.findIndex((candidate) => candidate.id === folder.id)
        return updateSmartFolder(folder.id, { name: folder.name, position })
      }))
      await queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    } finally {
      setIsReordering(false)
    }
  }

  function clearSavedFolderDrag() {
    dragIndex.current = null
  }

  return (
    <aside aria-label="Dashboard smart folders panel" className="space-y-2">
      <nav aria-label="Dashboard smart folders" className="space-y-1">
        {payload.subject === "job" ? null : allJobsLink}
        {primaryFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} onSelect={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })} prefix={prefix} />)}
        {moreFolders.length > 0 || payload.subject === "job" ? (
          <details className="space-y-1" open={allJobsSelected || moreFolders.some((folder) => folder.active) || undefined}>
            <summary className="list-none cursor-pointer rounded px-2 py-1.5 text-sm font-medium text-gray-600 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800">More</summary>
            <div className="space-y-1 pl-2">
              {payload.subject === "job" ? allJobsLink : null}
              {moreFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} onSelect={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })} prefix={prefix} />)}
            </div>
          </details>
        ) : null}
      </nav>
      <div className="space-y-1 pt-3">
        <h3 className="px-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Saved</h3>
        {savedFolders.length > 0 ? (
          <nav aria-label="Saved smart folders" className="space-y-1">
            {orderedSavedFolders.map((folder, index) => (
              <SmartFolderLink
                draggable={!isReordering}
                folder={folder}
                key={folder.id}
                onDragEnd={clearSavedFolderDrag}
                onDragOver={(event) => dragOverSavedFolder(index, event)}
                onDragStart={(event) => startSavedFolderDrag(index, event)}
                onDrop={dropSavedFolder}
                onSelect={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })}
                prefix={prefix}
                showDragHandle
              />
            ))}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400 dark:text-gray-500">No saved folders</p>
        )}
      </div>
      {canUpdateFilter && activeFolder ? (
        <div className="space-y-2 px-2 pt-3">
          <button
            className="w-full rounded border border-blue-300 px-3 py-1.5 text-sm font-medium text-blue-700 break-words hover:bg-blue-50 disabled:border-gray-200 disabled:text-gray-300 dark:border-blue-800 dark:text-blue-200 dark:hover:bg-blue-950 dark:disabled:border-gray-700 dark:disabled:text-gray-600"
            disabled={updateFolder.isPending}
            onClick={() => updateFolder.mutate()}
            type="button"
          >
            Update {activeFolder.name}
          </button>
          {updateFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(updateFolder.error, "Unable to update smart folder.")}</p> : null}
        </div>
      ) : null}
      {canSaveFilter ? (
        <form className="space-y-2 px-2 pt-3" onSubmit={saveFolder}>
          <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="dashboard-smart-folder-name">
            Folder name
            <input
              className="mt-1 block w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
              disabled={createFolder.isPending}
              id="dashboard-smart-folder-name"
              maxLength={120}
              onChange={(event) => setFolderName(event.target.value)}
              required
              type="text"
              value={folderName}
            />
          </label>
          <button className="w-full rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-gray-300 dark:hover:bg-blue-500 dark:disabled:bg-gray-700 dark:disabled:text-gray-400" disabled={createFolder.isPending} type="submit">
            Save folder
          </button>
          {createFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(createFolder.error, "Unable to save smart folder.")}</p> : null}
        </form>
      ) : null}
      {payload.landing_queue.visible ? (
        <div className="space-y-2 rounded border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-900">
          <button
            className="w-full rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:text-gray-300 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
            disabled={landingPause.isPending}
            onClick={() => landingPause.mutate()}
            type="button"
          >
            {payload.landing_queue.paused ? "Resume landing" : "Pause landing"}
          </button>
          <NoticeToast message={landingPause.isSuccess ? landingPause.data.message : null} onDismiss={() => landingPause.reset()} />
          {landingPause.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(landingPause.error, "Unable to update landing queue.")}</p> : null}
        </div>
      ) : null}
    </aside>
  )
}

function SmartFolderLink({
  draggable = false,
  folder,
  onDragEnd,
  onDragOver,
  onDragStart,
  onDrop,
  onSelect,
  prefix,
  showDragHandle = false
}: {
  draggable?: boolean
  folder: DashboardSmartFolder
  onDragEnd?: () => void
  onDragOver?: (event: DragEvent<HTMLElement>) => void
  onDragStart?: (event: DragEvent<HTMLElement>) => void
  onDrop?: (event: DragEvent<HTMLElement>) => void
  onSelect?: () => void
  prefix: string
  showDragHandle?: boolean
}) {
  const queryClient = useQueryClient()
  const [menuOpen, setMenuOpen] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(folder.name)
  const [deleteArmed, setDeleteArmed] = useState(false)
  const [actionsVisible, setActionsVisible] = useState(false)
  const ignoreNextBlurRef = useRef(false)
  const popupRef = useDismissiblePopup<HTMLDivElement>(menuOpen, () => {
    setMenuOpen(false)
    setDeleteArmed(false)
  })
  const update = useMutation({
    mutationFn: () => updateSmartFolder(folder.id, { name, position: folder.position }),
    onSuccess: () => {
      setRenaming(false)
      setMenuOpen(false)
      setDeleteArmed(false)
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteSmartFolder(folder.id),
    onSuccess: () => {
      setMenuOpen(false)
      setDeleteArmed(false)
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })

  function startRename() {
    setName(folder.name)
    setRenaming(true)
    setMenuOpen(false)
    setDeleteArmed(false)
    update.reset()
  }

  function confirmRename() {
    if (update.isPending) return
    update.mutate()
  }

  function cancelRename() {
    setName(folder.name)
    setRenaming(false)
    update.reset()
  }

  function handleRenameKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Enter") {
      event.preventDefault()
      confirmRename()
    } else if (event.key === "Escape") {
      event.preventDefault()
      ignoreNextBlurRef.current = true
      cancelRename()
    }
  }

  function handleBlur(event: FocusEvent<HTMLDivElement>) {
    if (!event.currentTarget.contains(event.relatedTarget)) {
      setActionsVisible(false)
    }
  }

  if (folder.kind === "user_defined") {
    const error = update.isError ? errorMessage(update.error, "Unable to rename smart folder.") : destroy.isError ? errorMessage(destroy.error, "Unable to delete smart folder.") : null
    const showActions = actionsVisible || menuOpen

    return (
      <div className="space-y-1">
        <div
          ref={popupRef}
          className={`relative flex min-w-0 items-center gap-1 rounded ${showDragHandle ? "group cursor-grab active:cursor-grabbing" : ""} ${folder.active ? "bg-blue-50 font-medium text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`}
          draggable={draggable}
          onBlur={handleBlur}
          onDragEnd={onDragEnd}
          onDragOver={onDragOver}
          onDragStart={onDragStart}
          onDrop={onDrop}
          onFocus={() => setActionsVisible(true)}
          onMouseEnter={() => setActionsVisible(true)}
          onMouseLeave={() => {
            if (!menuOpen) setActionsVisible(false)
          }}
        >
          {renaming ? (
            <div className="flex min-w-0 flex-1 items-center justify-between gap-2 rounded-l px-2 py-1.5 text-sm">
              <input
                aria-label={`Rename ${folder.name}`}
                autoFocus
                className="min-w-0 flex-1 rounded border border-gray-300 bg-white px-1.5 py-0.5 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                disabled={update.isPending}
                maxLength={120}
                onBlur={() => {
                  if (ignoreNextBlurRef.current) {
                    ignoreNextBlurRef.current = false
                    return
                  }
                  confirmRename()
                }}
                onChange={(event) => setName(event.target.value)}
                onKeyDown={handleRenameKeyDown}
                value={name}
              />
            </div>
          ) : (
            <Link aria-label={`${folder.name} ${folder.count}`} className="flex min-w-0 flex-1 items-center gap-2 rounded-l px-2 py-1.5 text-sm" onClick={onSelect} to={withRoutePrefix(folder.path, prefix)}>
              {showDragHandle ? <GripIcon /> : null}
              <span className="truncate">{folder.name}</span>
            </Link>
          )}
          <div className="mr-1 flex h-7 w-7 shrink-0 items-center justify-center">
            {showActions ? (
              <button
                aria-expanded={menuOpen}
                aria-haspopup="menu"
                aria-label={`Actions for ${folder.name}`}
                className="inline-flex h-7 w-7 items-center justify-center rounded text-gray-500 hover:bg-gray-200 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100"
                onClick={(event) => {
                  event.stopPropagation()
                  setMenuOpen((open) => !open)
                  setDeleteArmed(false)
                  destroy.reset()
                }}
                type="button"
              >
                ...
              </button>
            ) : (
              <FolderCount folder={folder} />
            )}
          </div>
          {menuOpen ? (
            <div className="absolute right-0 top-8 z-20 min-w-36 rounded border border-gray-200 bg-white py-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-900" role="menu">
              <button className="block w-full px-3 py-1.5 text-left text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800" onClick={startRename} role="menuitem" type="button">
                Rename
              </button>
              <button
                className="block w-full px-3 py-1.5 text-left text-red-700 hover:bg-red-50 dark:text-red-300 dark:hover:bg-red-950"
                disabled={destroy.isPending}
                onClick={() => {
                  if (deleteArmed) {
                    destroy.mutate()
                  } else {
                    setDeleteArmed(true)
                  }
                }}
                role="menuitem"
                type="button"
              >
                {deleteArmed ? "Confirm delete?" : "Delete"}
              </button>
            </div>
          ) : null}
        </div>
        {error ? <p className="px-2 text-xs text-red-700 dark:text-red-300" role="alert">{error}</p> : null}
      </div>
    )
  }
  return (
    <Link
      aria-label={`${folder.name} ${folder.count}`}
      className={folderClass(folder.active, showDragHandle)}
      draggable={draggable}
      onDragEnd={onDragEnd}
      onDragOver={onDragOver}
      onDragStart={onDragStart}
      onDrop={onDrop}
      onClick={onSelect}
      to={withRoutePrefix(folder.path, prefix)}
    >
      {showDragHandle ? <GripIcon /> : null}
      <span className="truncate">{folder.name}</span>
      <FolderCount folder={folder} />
    </Link>
  )
}

function FolderCount({ folder }: { folder: DashboardSmartFolder }) {
  return <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${folder.active ? "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{folder.count}</span>
}

function reorderFolders(folders: DashboardSmartFolder[], sourceIndex: number, targetIndex: number) {
  const reordered = [...folders]
  const [moved] = reordered.splice(sourceIndex, 1)
  reordered.splice(targetIndex, 0, moved)
  return reordered
}

function GripIcon() {
  return (
    <svg aria-hidden="true" className="-ml-1 size-4 shrink-0 text-gray-400 opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100 dark:text-gray-500" fill="none" viewBox="0 0 16 16">
      <circle cx="6" cy="4" fill="currentColor" r="1" />
      <circle cx="10" cy="4" fill="currentColor" r="1" />
      <circle cx="6" cy="8" fill="currentColor" r="1" />
      <circle cx="10" cy="8" fill="currentColor" r="1" />
      <circle cx="6" cy="12" fill="currentColor" r="1" />
      <circle cx="10" cy="12" fill="currentColor" r="1" />
    </svg>
  )
}

function subjectPath(subject: DashboardSubject) {
  if (subject === "job") return "/dashboard/jobs"
  if (subject === "workflow") return "/dashboard/workflows"

  return "/dashboard/epics"
}

function subjectLabel(subject: DashboardSubject, count: number) {
  const label = subject === "job" ? "job" : subject
  return count === 1 ? label : `${label}s`
}

function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

function clearDashboardFilterOverrides(path: string, search: string) {
  const params = new URLSearchParams(search)
  params.delete("page")
  for (const key of dashboardFilterOverrideKeys) params.delete(key)

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function mergeFilterTrees(baseTree: FilterTree, overrideTree: FilterTree): FilterTree {
  const children: FilterNode[] = [
    ...topFilterChildren(baseTree),
    ...topFilterChildren(overrideTree)
  ]

  return { and: children }
}

function folderClass(active: boolean, withDragHandle = false) {
  return `flex min-w-0 items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${withDragHandle ? "group cursor-grab active:cursor-grabbing" : ""} ${active ? "bg-blue-50 font-medium text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
