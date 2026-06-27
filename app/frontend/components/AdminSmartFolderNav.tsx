import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { DragEvent, FormEvent, KeyboardEvent } from "react"
import { useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { createSmartFolder, deleteSmartFolder, updateSmartFolder } from "../api/smartFolders"
import { filterTreeFromPayload, filterTreesEqual, topFilterChildren } from "./FilterBar"

export function AdminSmartFolderNav({
  activeFolderId,
  allLabel,
  allPath,
  ariaLabel,
  currentFilter,
  folders,
  heading,
  onMutationSuccess,
  prefix,
  queryKey,
  subjectType
}: {
  activeFolderId?: number | null
  allLabel: string
  allPath: string
  appliedFilter?: Record<string, unknown> | null
  ariaLabel: string
  currentFilter?: Record<string, unknown>
  folders: AdminSmartFolder[]
  heading: string
  onNavigate?: (path: string) => void
  onMutationSuccess?: () => void
  prefix: string
  queryKey?: unknown[]
  search?: string
  subjectType?: string
}) {
  const queryClient = useQueryClient()
  const [draggedFolderId, setDraggedFolderId] = useState<number | null>(null)
  const location = useLocation()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = folders.filter((folder) => folder.kind === "user_defined")
  const activeFolder = savedFolders.find((folder) => folder.id === activeFolderId)
  const currentTree = filterTreeFromPayload(currentFilter)
  const selectedFolder = folders.find((folder) => folder.id === activeFolderId)
  const filtersDiffer = selectedFolder?.filter != null && !filterTreesEqual(currentTree, filterTreeFromPayload(selectedFolder.filter))
  const canSaveAsNew = topFilterChildren(currentTree).length > 0 && Boolean(subjectType) && filtersDiffer
  const createFolder = useMutation({
    mutationFn: () => {
      if (!currentFilter || !subjectType) throw new Error("No filter to save.")

      return createSmartFolder({
        name: folderName,
        subjectType,
        filter: currentFilter
      })
    },
    onSuccess: (data) => {
      setFolderName("")
      if (data.redirect_to) {
        navigate(withRoutePrefix(data.redirect_to, prefix), { replace: true })
      } else {
        navigate(cleanFilterOverrideUrl(location), { replace: true })
      }
      if (queryKey) void queryClient.invalidateQueries({ queryKey })
      onMutationSuccess?.()
    }
  })
  const updateFolder = useMutation({
    mutationFn: () => {
      if (!activeFolder || !currentFilter) throw new Error("No active smart folder to update.")

      return updateSmartFolder(activeFolder.id, {
        name: activeFolder.name,
        position: activeFolder.position,
        filter: currentFilter
      })
    },
    onSuccess: () => {
      navigate(cleanFilterOverrideUrl(location), { replace: true })
      if (queryKey) void queryClient.invalidateQueries({ queryKey })
      onMutationSuccess?.()
    }
  })

  function saveFolder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    createFolder.mutate()
  }

  const reorder = useMutation({
    mutationFn: (nextFolders: AdminSmartFolder[]) => {
      return Promise.all(
        nextFolders.map((folder, index) => updateSmartFolder(folder.id, { name: folder.name, position: index }))
      )
    },
    onSuccess: () => {
      onMutationSuccess?.()
    }
  })

  function dragSavedFolder(event: DragEvent<HTMLElement>, folder: AdminSmartFolder) {
    setDraggedFolderId(folder.id)
    event.dataTransfer.effectAllowed = "move"
    event.dataTransfer.setData("text/plain", String(folder.id))
  }

  function dragOverSavedFolder(event: DragEvent<HTMLElement>) {
    if (draggedFolderId != null) event.preventDefault()
  }

  function dropSavedFolder(event: DragEvent<HTMLElement>, targetFolder: AdminSmartFolder) {
    event.preventDefault()
    const sourceId = Number(event.dataTransfer.getData("text/plain") || draggedFolderId)
    setDraggedFolderId(null)
    if (!sourceId || sourceId === targetFolder.id || reorder.isPending) return

    const sourceIndex = savedFolders.findIndex((folder) => folder.id === sourceId)
    const targetIndex = savedFolders.findIndex((folder) => folder.id === targetFolder.id)
    if (sourceIndex < 0 || targetIndex < 0) return

    const nextFolders = [...savedFolders]
    const [moved] = nextFolders.splice(sourceIndex, 1)
    nextFolders.splice(targetIndex, 0, moved)
    reorder.mutate(nextFolders)
  }

  return (
    <aside className="space-y-2">
      <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{heading}</h2>
      <nav aria-label={ariaLabel} className="space-y-1">
        <Link className={folderClass(activeFolderId == null)} to={withRoutePrefix(allPath, prefix)}>
          <span className="truncate">{allLabel}</span>
        </Link>
        {primaryFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
        {moreFolders.length > 0 ? (
          <details className="space-y-1" open={moreFolders.some((folder) => folder.active) || undefined}>
            <summary className="cursor-pointer rounded px-2 py-1.5 text-sm font-medium text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 dark:bg-gray-800">More</summary>
            <div className="space-y-1 pl-2">
              {moreFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
            </div>
          </details>
        ) : null}
      </nav>
      <div className="space-y-1 pt-3">
        <h3 className="px-2 text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Saved</h3>
        {savedFolders.length > 0 ? (
          <nav aria-label={`${ariaLabel} saved`} className="space-y-1">
            {savedFolders.map((folder) => (
              <SmartFolderLink
                draggable={!reorder.isPending}
                folder={folder}
                key={folder.id}
                onDragEnd={() => setDraggedFolderId(null)}
                onDragOver={dragOverSavedFolder}
                onDragStart={(event) => dragSavedFolder(event, folder)}
                onDrop={(event) => dropSavedFolder(event, folder)}
                onMutationSuccess={onMutationSuccess}
                prefix={prefix}
              />
            ))}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400">No saved folders</p>
        )}
        {filtersDiffer && activeFolder ? (
          <div className="space-y-2 px-2 pt-2">
            <button
              className="w-full rounded border border-blue-200 bg-blue-50 px-2 py-1.5 text-sm font-medium text-blue-700 hover:bg-blue-100 disabled:cursor-not-allowed disabled:border-gray-200 disabled:bg-gray-50 disabled:text-gray-400 dark:border-blue-900 dark:bg-blue-950/40 dark:text-blue-300 dark:hover:bg-blue-950 dark:disabled:border-gray-700 dark:disabled:bg-gray-900 dark:disabled:text-gray-600"
              disabled={updateFolder.isPending}
              onClick={() => updateFolder.mutate()}
              type="button"
            >
              {updateFolder.isPending ? "Updating..." : `Update ${activeFolder.name}`}
            </button>
            {updateFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">Unable to update smart folder.</p> : null}
          </div>
        ) : null}
        {canSaveAsNew ? (
          <div className="space-y-2 px-2 pt-2">
            <form className="space-y-2" onSubmit={saveFolder}>
              <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${subjectType}-smart-folder-name`}>
                Folder name
                <input
                  className="mt-1 block w-full rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                  disabled={createFolder.isPending}
                  id={`${subjectType}-smart-folder-name`}
                  maxLength={120}
                  onChange={(event) => setFolderName(event.target.value)}
                  required
                  type="text"
                  value={folderName}
                />
              </label>
              <button className="w-full rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-gray-300 dark:hover:bg-blue-500 dark:disabled:bg-gray-700 dark:disabled:text-gray-400" disabled={createFolder.isPending} type="submit">
                {createFolder.isPending ? "Saving..." : "Save as new folder"}
              </button>
              {createFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">Unable to save smart folder.</p> : null}
            </form>
          </div>
        ) : null}
      </div>
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
  onMutationSuccess,
  prefix
}: {
  draggable?: boolean
  folder: AdminSmartFolder
  onDragEnd?: () => void
  onDragOver?: (event: DragEvent<HTMLElement>) => void
  onDragStart?: (event: DragEvent<HTMLElement>) => void
  onDrop?: (event: DragEvent<HTMLElement>) => void
  onMutationSuccess?: () => void
  prefix: string
}) {
  const [menuOpen, setMenuOpen] = useState(false)
  const [editing, setEditing] = useState(false)
  const [name, setName] = useState(folder.name)
  const [confirmDelete, setConfirmDelete] = useState(false)
  const isUserDefined = folder.kind === "user_defined"
  const rename = useMutation({
    mutationFn: () => updateSmartFolder(folder.id, { name: name.trim(), position: folder.position }),
    onSuccess: () => {
      setEditing(false)
      setMenuOpen(false)
      onMutationSuccess?.()
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteSmartFolder(folder.id),
    onSuccess: () => {
      setMenuOpen(false)
      setConfirmDelete(false)
      onMutationSuccess?.()
    }
  })

  function startRename() {
    setName(folder.name)
    setEditing(true)
    setMenuOpen(false)
  }

  function keyRename(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Escape") {
      setName(folder.name)
      setEditing(false)
    } else if (event.key === "Enter" && name.trim().length > 0) {
      rename.mutate()
    }
  }

  if (!isUserDefined) {
    return (
      <Link aria-label={`${folder.name} ${folder.count}`} className={folderClass(folder.active)} to={withRoutePrefix(folder.path, prefix)}>
        <span className="truncate">{folder.name}</span>
        <FolderCount active={folder.active} count={folder.count} />
      </Link>
    )
  }

  if (editing) {
    return (
      <div className={folderClass(folder.active)}>
        <input
          aria-label={`Rename ${folder.name}`}
          autoFocus
          className="min-w-0 flex-1 rounded border border-gray-300 bg-white px-2 py-1 text-sm text-gray-900 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          disabled={rename.isPending}
          maxLength={120}
          onChange={(event) => setName(event.target.value)}
          onKeyDown={keyRename}
          value={name}
        />
        <FolderCount active={folder.active} count={folder.count} />
      </div>
    )
  }

  return (
    <div
      className={`${folderClass(folder.active)} relative`}
      draggable={draggable}
      onDragEnd={onDragEnd}
      onDragOver={onDragOver}
      onDragStart={onDragStart}
      onDrop={onDrop}
    >
      <span aria-label={`Drag ${folder.name}`} className="cursor-grab select-none text-xs text-gray-400" role="img">::</span>
      <Link aria-label={`${folder.name} ${folder.count}`} className="min-w-0 flex-1 truncate" to={withRoutePrefix(folder.path, prefix)}>
        {folder.name}
      </Link>
      <FolderCount active={folder.active} count={folder.count} />
      <button
        aria-expanded={menuOpen}
        aria-haspopup="menu"
        aria-label={`Manage ${folder.name}`}
        className="rounded px-1 text-gray-400 hover:bg-gray-200 hover:text-gray-700 dark:hover:bg-gray-700 dark:hover:text-gray-100"
        onClick={() => {
          setMenuOpen((open) => !open)
          setConfirmDelete(false)
        }}
        type="button"
      >
        ...
      </button>
      {menuOpen ? (
        <div className="absolute right-0 top-8 z-20 min-w-36 rounded border border-gray-200 bg-white p-1 text-sm shadow-lg dark:border-gray-700 dark:bg-gray-900" role="menu">
          <button className={menuItemClass()} onClick={startRename} role="menuitem" type="button">Rename</button>
          <button
            className={menuItemClass("text-red-700 dark:text-red-300")}
            disabled={destroy.isPending}
            onClick={() => confirmDelete ? destroy.mutate() : setConfirmDelete(true)}
            role="menuitem"
            type="button"
          >
            {confirmDelete ? "Confirm delete" : "Delete"}
          </button>
        </div>
      ) : null}
    </div>
  )
}

function FolderCount({ active, count }: { active: boolean; count: number }) {
  return (
    <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${active ? "bg-blue-100 dark:bg-blue-950/60 text-blue-700 dark:text-blue-300" : "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"}`}>{count}</span>
  )
}

function folderClass(active: boolean) {
  return `flex min-w-0 items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${active ? "bg-blue-50 dark:bg-blue-950/40 font-medium text-blue-700 dark:text-blue-300" : "text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 dark:bg-gray-800"}`
}

function menuItemClass(extra = "") {
  return `block w-full rounded px-3 py-2 text-left text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800 ${extra}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function cleanFilterOverrideUrl(location: { pathname: string; search: string }) {
  const params = new URLSearchParams(location.search)
  params.delete("q")
  const qs = params.toString()

  return qs ? `${location.pathname}?${qs}` : location.pathname
}
