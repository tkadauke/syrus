import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link } from "react-router-dom"
import { ApiError } from "../api/client"
import { createAdminSmartFolder, type AdminSmartFolder } from "../api/adminSmartFolders"
import { filterTreeFromPayload, smartFolderFiltersFromTree, topFilterChildren } from "./FilterBar"

export function AdminSmartFolderNav({
  activeSmartFolderId,
  allLabel,
  allPath,
  appliedFilter,
  ariaLabel,
  folders,
  heading,
  onNavigate,
  prefix,
  queryKey,
  subjectType
}: {
  activeSmartFolderId: number | null
  allLabel: string
  allPath: string
  appliedFilter?: Record<string, unknown> | null
  ariaLabel: string
  folders: AdminSmartFolder[]
  heading: string
  onNavigate?: (path: string) => void
  prefix: string
  queryKey?: unknown[]
  subjectType: string
}) {
  const queryClient = useQueryClient()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = folders.filter((folder) => folder.kind === "user_defined")
  const appliedTree = filterTreeFromPayload(appliedFilter)
  const canSaveFilter = topFilterChildren(appliedTree).length > 0 && activeSmartFolderId == null && Boolean(queryKey && onNavigate)
  const createFolder = useMutation({
    mutationFn: () => createAdminSmartFolder({
      name: folderName,
      subjectType,
      filters: smartFolderFiltersFromTree(appliedTree)
    }),
    onSuccess: (result) => {
      setFolderName("")
      if (queryKey) void queryClient.invalidateQueries({ queryKey })
      onNavigate?.(result.redirect_to)
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
        <Link className={folderClass(activeSmartFolderId == null)} to={withRoutePrefix(allPath, prefix)}>
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
      </div>
      {canSaveFilter ? (
        <form className="space-y-2 px-2 pt-3" onSubmit={saveFolder}>
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
            Save folder
          </button>
          {createFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(createFolder.error, "Unable to save smart folder.")}</p> : null}
        </form>
      ) : null}
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

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
