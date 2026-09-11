import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import type { AdminSmartFolder } from "../api/adminSmartFolders"
import { createSmartFolder, updateSmartFolder } from "../api/smartFolders"
import { useT } from "../hooks/useT"
import { withRoutePrefix } from "../lib/routing"
import { Button } from "./Button"
import { Input } from "./Input"
import { filterTreeFromPayload, filterTreesEqual, topFilterChildren } from "./FilterBar"
import { SmartFolderNavigation } from "./SmartFolderNavigation"

export function AdminSmartFolderNav({
  activeFolderId,
  allLabel,
  allPath,
  allowSaveWithoutActiveFolder = false,
  ariaLabel,
  currentFilter,
  folders,
  heading,
  onMutationSuccess,
  prefix,
  queryKey,
  rewriteRedirectTo,
  subjectType
}: {
  activeFolderId?: number | null
  allLabel: string
  allPath: string
  allowSaveWithoutActiveFolder?: boolean
  appliedFilter?: Record<string, unknown> | null
  ariaLabel: string
  currentFilter?: Record<string, unknown>
  folders: AdminSmartFolder[]
  heading: string
  onNavigate?: (path: string) => void
  onMutationSuccess?: () => void
  prefix: string
  queryKey?: unknown[]
  rewriteRedirectTo?: (path: string) => string
  search?: string
  subjectType?: string
}) {
  const { t } = useT("nav")
  const queryClient = useQueryClient()
  const location = useLocation()
  const navigate = useNavigate()
  const [folderName, setFolderName] = useState("")
  const savedFolders = folders.filter((folder) => folder.kind === "user_defined")
  const activeFolder = savedFolders.find((folder) => folder.id === activeFolderId)
  const currentTree = filterTreeFromPayload(currentFilter)
  const selectedFolder = folders.find((folder) => folder.id === activeFolderId)
  const filtersDiffer = selectedFolder?.filter != null && !filterTreesEqual(currentTree, filterTreeFromPayload(selectedFolder.filter))
  const canSaveAsNew = topFilterChildren(currentTree).length > 0 && Boolean(subjectType) && (filtersDiffer || (allowSaveWithoutActiveFolder && selectedFolder == null))
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
        navigate(withRoutePrefix(rewriteRedirectTo ? rewriteRedirectTo(data.redirect_to) : data.redirect_to, prefix), { replace: true })
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

  return (
    <aside className="space-y-2">
      <SmartFolderNavigation
        actionLabel={(folder) => `Manage ${folder.name}`}
        allLink={{
          active: activeFolderId == null,
          label: allLabel,
          path: allPath
        }}
        ariaLabel={ariaLabel}
        emptySavedMessage={t("smart_folder.no_saved_folders")}
        folders={folders}
        getDisplayName={(folder) => folder.i18n_key
          ? t(`smart_folder_names.${folder.i18n_key}`, { defaultValue: folder.name })
          : folder.name}
        heading={heading}
        moreLabel={t("smart_folder.more")}
        onMutationSuccess={onMutationSuccess}
        prefix={prefix}
        queryKey={queryKey}
        savedAriaLabel={`${ariaLabel} saved`}
        savedHeading={t("smart_folder.saved")}
      />
      <div className="space-y-1">
        {filtersDiffer && activeFolder ? (
          <div className="space-y-2 px-2 pt-3">
            <button
              className="w-full rounded border border-brand/40 px-3 py-1.5 text-sm font-medium text-brand break-words hover:bg-brand/10 disabled:border-gray-200 disabled:text-gray-300 dark:text-brand-emphasis dark:disabled:border-gray-700 dark:disabled:text-gray-600"
              disabled={updateFolder.isPending}
              onClick={() => updateFolder.mutate()}
              type="button"
            >
              {updateFolder.isPending ? t("smart_folder.updating") : t("smart_folder.update_named_folder", { name: activeFolder.name })}
            </button>
            {updateFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{t("smart_folder.unable_to_update")}</p> : null}
          </div>
        ) : null}
        {canSaveAsNew ? (
          <div className="space-y-2 px-2 pt-3">
            <form className="space-y-2" onSubmit={saveFolder}>
              <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor={`${subjectType}-smart-folder-name`}>
                {t("smart_folder.folder_name")}
                <Input
                  className="mt-1"
                  disabled={createFolder.isPending}
                  id={`${subjectType}-smart-folder-name`}
                  maxLength={120}
                  onChange={(event) => setFolderName(event.target.value)}
                  required
                  type="text"
                  value={folderName}
                />
              </label>
              <Button className="w-full" disabled={createFolder.isPending} type="submit">
                {createFolder.isPending ? t("smart_folder.saving") : t("smart_folder.save_as_new_folder")}
              </Button>
              {createFolder.isError ? <p className="text-xs text-red-700 dark:text-red-300" role="alert">{t("smart_folder.unable_to_save")}</p> : null}
            </form>
          </div>
        ) : null}
      </div>
    </aside>
  )
}

function cleanFilterOverrideUrl(location: { pathname: string; search: string }) {
  const params = new URLSearchParams(location.search)
  params.delete("q")
  const qs = params.toString()

  return qs ? `${location.pathname}?${qs}` : location.pathname
}
