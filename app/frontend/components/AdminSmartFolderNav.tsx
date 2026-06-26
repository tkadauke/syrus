import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link } from "react-router-dom"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { createSmartFolder, updateSmartFolder } from "../api/smartFolders"

export function AdminSmartFolderNav({
  activeFolderId,
  allLabel,
  allPath,
  ariaLabel,
  currentFilter,
  folders,
  heading,
  invalidateQueryKey,
  prefix,
  search,
  subjectType
}: {
  activeFolderId?: number | null
  allLabel: string
  allPath: string
  ariaLabel: string
  currentFilter?: Record<string, unknown>
  folders: AdminSmartFolder[]
  heading: string
  invalidateQueryKey?: readonly unknown[]
  prefix: string
  search: string
  subjectType: string
}) {
  const queryClient = useQueryClient()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = folders.filter((folder) => folder.kind === "user_defined")
  const activeFolder = savedFolders.find((folder) => folder.id === activeFolderId)
  const hasUrlFilterOverride = new URLSearchParams(search).has("q")
  const filtersDiffer = Boolean(activeFolder && hasUrlFilterOverride)
  const hasCurrentFilter = Boolean(currentFilter && topFilterChildren(currentFilter).length > 0)
  const canSaveAsNew = hasCurrentFilter && (!activeFolder || filtersDiffer)
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
      if (invalidateQueryKey) void queryClient.invalidateQueries({ queryKey: invalidateQueryKey })
    }
  })
  const createFolder = useMutation({
    mutationFn: () => {
      if (!currentFilter) throw new Error("No filter to save.")

      return createSmartFolder({
        name: folderName,
        subjectType,
        filter: currentFilter
      })
    },
    onSuccess: () => {
      setFolderName("")
      if (invalidateQueryKey) void queryClient.invalidateQueries({ queryKey: invalidateQueryKey })
    }
  })

  function saveFolder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    createFolder.mutate()
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
        <div className="flex items-center justify-between gap-2 px-2">
          <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Saved</h3>
          <Link className="text-xs font-medium text-blue-700 dark:text-blue-300 hover:text-blue-900" to={`${prefix}/smart_folders?subject_type=${subjectType}`}>Manage</Link>
        </div>
        {savedFolders.length > 0 ? (
          <nav aria-label={`${ariaLabel} saved`} className="space-y-1">
            {savedFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} prefix={prefix} />)}
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

function SmartFolderLink({ folder, prefix }: { folder: AdminSmartFolder; prefix: string }) {
  return (
    <Link aria-label={`${folder.name} ${folder.count}`} className={folderClass(folder.active)} to={withRoutePrefix(folder.path, prefix)}>
      <span className="truncate">{folder.name}</span>
      <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${folder.active ? "bg-blue-100 dark:bg-blue-950/60 text-blue-700 dark:text-blue-300" : "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"}`}>{folder.count}</span>
    </Link>
  )
}

function folderClass(active: boolean) {
  return `flex items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${active ? "bg-blue-50 dark:bg-blue-950/40 font-medium text-blue-700 dark:text-blue-300" : "text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800 dark:bg-gray-800"}`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function topFilterChildren(filter: Record<string, unknown>): unknown[] {
  const children = filter.and
  return Array.isArray(children) ? children : []
}
