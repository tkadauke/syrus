import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import {
  deleteSmartFolder,
  fetchSmartFolders,
  updateSmartFolder,
  type SmartFolderRow,
  type SmartFoldersPayload
} from "../api/smartFolders"

const subjects = [
  ["job", "Jobs"],
  ["epic", "Epics"],
  ["workflow", "Workflows"],
  ["admin_user", "Admin users"],
  ["admin_queue", "Admin queue"],
  ["spawned_process", "Processes"]
] as const

export function SmartFolders() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const [notice, setNotice] = useState<string | null>(null)
  const smartFolders = useQuery({
    queryKey: ["smart_folders", location.search],
    queryFn: () => fetchSmartFolders(location.search)
  })

  return (
    <main aria-label="Smart folders" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="flex flex-col gap-3 border-b border-gray-200 dark:border-gray-700 pb-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Smart folders</h1>
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
            Rename, reorder, or delete saved {smartFolders.data?.subject_label.toLowerCase() || "job"} filters.
          </p>
        </div>
        {smartFolders.data ? (
          <Link className="text-sm text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(smartFolders.data.dashboard_path, prefix)}>Back to dashboard</Link>
        ) : null}
      </header>

      <SubjectTabs activeSubject={smartFolders.data?.subject_type || subjectFromSearch(location.search)} />

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {smartFolders.isPending ? <PanelMessage>Loading smart folders...</PanelMessage> : null}
      {smartFolders.isError ? <SmartFoldersError error={smartFolders.error} /> : null}
      {smartFolders.isSuccess ? <SmartFoldersTable onNotice={setNotice} payload={smartFolders.data} querySearch={location.search} /> : null}
    </main>
  )
}

function SubjectTabs({ activeSubject }: { activeSubject: string }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""

  return (
    <nav aria-label="Smart folder subjects" className="flex flex-wrap gap-2">
      {subjects.map(([subject, label]) => (
        <Link
          className={`rounded border px-3 py-1.5 text-sm ${activeSubject === subject ? "border-gray-900 bg-gray-900 text-white dark:border-gray-100 dark:bg-gray-100 dark:text-gray-950" : "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800"}`}
          key={subject}
          to={`${prefix}/smart_folders?subject_type=${subject}`}
        >
          {label}
        </Link>
      ))}
    </nav>
  )
}

function SmartFoldersTable({ payload, querySearch, onNotice }: { payload: SmartFoldersPayload; querySearch: string; onNotice: (message: string | null) => void }) {
  return (
    <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      {payload.smart_folders.length === 0 ? (
        <PanelMessage>No saved smart folders yet.</PanelMessage>
      ) : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">Name</th>
              <th className="px-4 py-2">Position</th>
              <th className="px-4 py-2">Filter</th>
              <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
            {payload.smart_folders.map((folder) => (
              <SmartFolderTableRow folder={folder} key={folder.id} onNotice={onNotice} querySearch={querySearch} />
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function SmartFolderTableRow({ folder, querySearch, onNotice }: { folder: SmartFolderRow; querySearch: string; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [name, setName] = useState(folder.name)
  const [position, setPosition] = useState(folder.position)
  const update = useMutation({
    mutationFn: () => updateSmartFolder(folder.id, { name, position }),
    onSuccess: (payload) => {
      queryClient.setQueryData(["smart_folders", querySearch], payload)
      onNotice(payload.message || "Smart folder updated.")
    }
  })
  const destroy = useMutation({
    mutationFn: () => deleteSmartFolder(folder.id),
    onSuccess: (payload) => {
      queryClient.setQueryData(["smart_folders", querySearch], payload)
      onNotice(payload.message || "Smart folder deleted.")
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <tr>
      <td className="px-4 py-3">
        <form className="contents" onSubmit={submit}>
          <input
            aria-label={`Name for ${folder.name}`}
            className="w-full max-w-xs rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
            onChange={(event) => setName(event.target.value)}
            required
            type="text"
            value={name}
          />
        </form>
      </td>
      <td className="px-4 py-3">
        <input
          aria-label={`Position for ${folder.name}`}
          className="w-24 rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => setPosition(Number(event.target.value))}
          type="number"
          value={position}
        />
      </td>
      <td className="max-w-xl px-4 py-3 font-mono text-xs text-gray-600 dark:text-gray-400">
        <pre className="whitespace-pre-wrap break-words">{JSON.stringify(folder.filter)}</pre>
      </td>
      <td className="px-4 py-3 text-right">
        <div className="flex justify-end gap-2">
          <button
            className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
            disabled={update.isPending}
            onClick={() => {
              onNotice(null)
              update.mutate()
            }}
            type="button"
          >
            {update.isPending ? "Saving..." : "Save"}
          </button>
          <button
            className="text-sm text-red-600 dark:text-red-300 underline hover:no-underline disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
            disabled={destroy.isPending}
            onClick={() => {
              if (window.confirm(`Delete ${folder.name}?`)) {
                onNotice(null)
                destroy.mutate()
              }
            }}
            type="button"
          >
            {destroy.isPending ? "Deleting..." : "Delete"}
          </button>
        </div>
        {update.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, "Unable to update smart folder.")}</p> : null}
        {destroy.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(destroy.error, "Unable to delete smart folder.")}</p> : null}
      </td>
    </tr>
  )
}

function SmartFoldersError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load smart folders.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-400"}`}>{children}</div>
}

function subjectFromSearch(search: string) {
  return new URLSearchParams(search).get("subject_type") || "job"
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
