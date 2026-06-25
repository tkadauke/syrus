import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { ApiError } from "../api/client"
import { createDashboardSmartFolder, toggleDashboardLandingPause, updateDashboardPreferences, type DashboardPayload, type DashboardSmartFolder, type DashboardSubject } from "../api/dashboard"
import { filterTreeFromPayload, smartFolderFiltersFromTree, topFilterChildren } from "./FilterBar"
import { NoticeToast } from "./NoticeToast"

export function DashboardSmartFolderNav({ payload, prefix, search }: { payload: DashboardPayload; prefix: string; search: string }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const builtinFolders = payload.smart_folders.filter((folder) => folder.kind !== "user_defined")
  const primaryFolders = builtinFolders.filter((folder) => folder.visibility !== "on_demand")
  const moreFolders = builtinFolders.filter((folder) => folder.visibility === "on_demand")
  const savedFolders = payload.smart_folders.filter((folder) => folder.kind === "user_defined")
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
        <div className="flex items-center justify-between gap-2 px-2">
          <h3 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">Saved</h3>
          <Link className="text-xs font-medium text-blue-700 hover:text-blue-900 dark:text-blue-300 dark:hover:text-blue-200" to={withRoutePrefix(`/smart_folders?subject_type=${payload.subject}`, prefix)}>Manage</Link>
        </div>
        {savedFolders.length > 0 ? (
          <nav aria-label="Saved smart folders" className="space-y-1">
            {savedFolders.map((folder) => <SmartFolderLink folder={folder} key={folder.id} onSelect={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })} prefix={prefix} />)}
          </nav>
        ) : (
          <p className="px-2 py-1.5 text-sm text-gray-400 dark:text-gray-500">No saved folders</p>
        )}
      </div>
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

function SmartFolderLink({ folder, onSelect, prefix }: { folder: DashboardSmartFolder; onSelect: () => void; prefix: string }) {
  return (
    <Link aria-label={`${folder.name} ${folder.count}`} className={folderClass(folder.active)} onClick={onSelect} to={withRoutePrefix(folder.path, prefix)}>
      <span className="truncate">{folder.name}</span>
      <span className={`ml-auto inline-flex min-w-6 justify-center rounded-full px-1.5 py-0.5 text-xs ${folder.active ? "bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{folder.count}</span>
    </Link>
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

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function folderClass(active: boolean) {
  return `flex min-w-0 items-center justify-between gap-2 rounded px-2 py-1.5 text-sm ${active ? "bg-blue-50 font-medium text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
