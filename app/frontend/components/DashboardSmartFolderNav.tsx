import { withRoutePrefix } from "../lib/routing"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { useT } from "../hooks/useT"
import { createDashboardSmartFolder, toggleDashboardLandingPause, updateDashboardPreferences, type DashboardPayload, type DashboardSmartFolder, type DashboardSubject } from "../api/dashboard"
import { updateSmartFolder } from "../api/smartFolders"
import { Button } from "./Button"
import { Input } from "./Input"
import { filterTreeFromPayload, filterTreesEqual, smartFolderFiltersFromTree, topFilterChildren } from "./FilterBar"
import { NoticeToast } from "./NoticeToast"
import { errorMessage } from "../lib/errorMessage"
import { SmartFolderNavigation } from "./SmartFolderNavigation"

const dashboardFilterOverrideKeys = ["q", "state", "repository_id", "kind", "trigger_kind", "job_id", "attention", "start_blocked", "tag_ids", "pr", "age"]

type DashboardSmartFolderPayload = Pick<DashboardPayload, "active_smart_folder_id" | "broken_repositories" | "filter" | "health_blocked_repositories" | "landing_queue" | "ownership" | "rows_current_for_search" | "smart_folders" | "subject" | "view">

export function DashboardSmartFolderNav({ payload, prefix, search }: { payload: DashboardSmartFolderPayload; prefix: string; search: string }) {
  const { t } = useT("nav")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const savedFolders = payload.smart_folders.filter((folder) => folder.kind === "user_defined")
  const activeSmartFolderId = smartFolderIdFromSearch(search) ?? payload.active_smart_folder_id
  const activeFolder = savedFolders.find((folder) => folder.id === activeSmartFolderId)
  const updatePreferences = useMutation({
    mutationFn: updateDashboardPreferences,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
    }
  })
  const allPath = dashboardLink(subjectPath(payload.subject), { view: payload.view })
  const appliedTree = filterTreeFromPayload(payload.filter)
  const hasAppliedFilter = topFilterChildren(appliedTree).length > 0
  const selectedFolder = payload.smart_folders.find((folder) => folder.id === activeSmartFolderId)
  const rowsCurrentForSearch = payload.rows_current_for_search ?? true
  const filterChangedFromSelectedFolder = rowsCurrentForSearch && selectedFolder?.filter != null && !filterTreesEqual(appliedTree, filterTreeFromPayload(selectedFolder.filter))
  const canUpdateFilter = activeFolder != null && filterChangedFromSelectedFolder
  const canSaveFilter = hasAppliedFilter && (selectedFolder == null || filterChangedFromSelectedFolder)
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

  function saveFolder(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    createFolder.mutate()
  }

  return (
    <aside aria-label={t("smart_folders_panel_aria")} className="space-y-2">
      <SmartFolderNavigation
        actionLabel={(folder) => `Actions for ${folder.name}`}
        allLink={allSubjectLinkVisible(payload) ? {
          active: activeSmartFolderId == null,
          label: allSubjectLabel(payload.subject, t),
          onSelect: () => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: null }),
          path: allPath
        } : null}
        ariaLabel={t("smart_folders_aria")}
        emptySavedMessage={t("smart_folder.no_saved_folders")}
        folders={payload.smart_folders.map((folder) => folderWithActive(folder, activeSmartFolderId))}
        getDisplayName={(folder) => (folder.kind !== "user_defined" && folder.key)
          ? t(`smart_folder.names.${folder.key}`, { defaultValue: folder.name })
          : folder.name}
        moreLabel={t("smart_folder.more")}
        onMutationSuccess={() => {
          void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
        }}
        onSelect={(folder) => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })}
        prefix={prefix}
        renderCountPrefix={(folder) => <BlockedCount folder={folder} onSelect={() => updatePreferences.mutate({ subject: payload.subject, smart_folder_id: folder.id })} prefix={prefix} />}
        savedAriaLabel={t("saved_folders_aria")}
        savedHeading={t("smart_folder.saved")}
      />
      {canUpdateFilter && activeFolder ? (
        <div className="space-y-2 px-2 pt-3">
          <button
            className="w-full rounded border border-brand/40 px-3 py-1.5 text-sm font-medium text-brand break-words hover:bg-brand/10 disabled:border-gray-200 disabled:text-gray-300 dark:text-brand-emphasis dark:disabled:border-gray-700 dark:disabled:text-gray-600"
            disabled={updateFolder.isPending}
            onClick={() => updateFolder.mutate()}
            type="button"
          >
            {t("smart_folder.update_named_folder", { name: activeFolder.name })}
          </button>
          {updateFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(updateFolder.error, t("smart_folder.unable_to_update"))}</p> : null}
        </div>
      ) : null}
      {canSaveFilter ? (
        <form className="space-y-2 px-2 pt-3" onSubmit={saveFolder}>
          <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="dashboard-smart-folder-name">
            {t("smart_folder.folder_name")}
            <Input
              className="mt-1"
              disabled={createFolder.isPending}
              id="dashboard-smart-folder-name"
              maxLength={120}
              onChange={(event) => setFolderName(event.target.value)}
              required
              type="text"
              value={folderName}
            />
          </label>
          <Button className="w-full" disabled={createFolder.isPending} type="submit">
            {t("smart_folder.save_folder")}
          </Button>
          {createFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(createFolder.error, t("smart_folder.unable_to_save"))}</p> : null}
        </form>
      ) : null}
      {payload.landing_queue.visible ? (
        <div className="space-y-2 rounded border border-gray-200 bg-white p-2 dark:border-gray-700 dark:bg-gray-900">
          <Button className="w-full" disabled={landingPause.isPending} onClick={() => landingPause.mutate()} size="sm" variant="secondary">
            {payload.landing_queue.paused ? t("smart_folder.resume_landing") : t("smart_folder.pause_landing")}
          </Button>
          {payload.landing_queue.paused && (payload.health_blocked_repositories ?? payload.broken_repositories)?.some((repo) => repo.main_branch_repair_blocks_work) ? (
            <p className="text-xs text-amber-700 dark:text-amber-300">{t("smart_folder.landing_paused_main_health")}</p>
          ) : null}
          <NoticeToast message={landingPause.isSuccess ? landingPause.data.message : null} onDismiss={() => landingPause.reset()} />
          {landingPause.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(landingPause.error, t("smart_folder.unable_to_update_landing"))}</p> : null}
        </div>
      ) : null}
    </aside>
  )
}

function BlockedCount({ folder, onSelect, prefix }: { folder: DashboardSmartFolder; onSelect?: () => void; prefix: string }) {
  const { t } = useT("nav")
  const navigate = useNavigate()
  const blockedCount = folder.blocked_count ?? 0
  const blockedPath = dashboardLinkFromExisting(folder.path, { start_blocked: "1", page: null })

  if (blockedCount <= 0) return null

  return (
    <button
      aria-label={t("smart_folder.queued_blocked_filter_aria", { count: blockedCount })}
      className="rounded-full bg-amber-100 px-1.5 py-0.5 text-xs text-amber-700 hover:bg-amber-200 dark:bg-amber-900 dark:text-amber-200 dark:hover:bg-amber-800"
      onClick={(event) => {
        event.preventDefault()
        event.stopPropagation()
        onSelect?.()
        navigate(withRoutePrefix(blockedPath, prefix))
      }}
      type="button"
    >
      {t("smart_folder.queued_blocked_count", { count: blockedCount })}
    </button>
  )
}

function subjectPath(subject: DashboardSubject) {
  if (subject === "job") return "/dashboard/jobs"
  if (subject === "workflow") return "/dashboard/workflows"

  return "/dashboard/epics"
}

function allSubjectLinkVisible(payload: DashboardSmartFolderPayload) {
  if (payload.subject === "job") return false
  if (payload.subject === "epic" && payload.ownership.team_user_count <= 1) return false

  return true
}

function allSubjectLabel(subject: DashboardSubject, t: (key: string, options?: Record<string, unknown>) => string) {
  if (subject === "job") return t("smart_folder.all_items_job", { defaultValue: "All jobs" })
  if (subject === "epic") return t("smart_folder.all_items_epic", { defaultValue: "All epics" })
  return t("smart_folder.all_items_workflow", { defaultValue: "All workflows" })
}

function dashboardLink(path: string, params: Record<string, string | number | null | undefined>) {
  const search = new URLSearchParams()
  for (const [key, value] of Object.entries(params)) {
    if (value != null && String(value).length > 0) search.set(key, String(value))
  }

  const query = search.toString()
  return query ? `${path}?${query}` : path
}

function dashboardLinkFromExisting(path: string, updates: Record<string, string | number | null | undefined>) {
  const [basePath, existingSearch = ""] = path.split("?")
  const params = new URLSearchParams(existingSearch)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${basePath}?${query}` : basePath
}

function clearDashboardFilterOverrides(path: string, search: string) {
  const params = new URLSearchParams(search)
  params.delete("page")
  for (const key of dashboardFilterOverrideKeys) params.delete(key)

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function folderWithActive(folder: DashboardSmartFolder, activeSmartFolderId: number | null) {
  const active = folder.id === activeSmartFolderId
  return folder.active === active ? folder : { ...folder, active }
}

export function smartFolderIdFromSearch(search: string) {
  const value = new URLSearchParams(search).get("smart_folder_id")
  if (!value) return null

  const id = Number(value)
  return Number.isInteger(id) ? id : null
}
