import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import {
  createRepositoryDocument,
  deleteRepositoryDocument,
  fetchRepositoryDocuments,
  type RepositoryDocument,
  type RepositoryDocumentInput,
  type RepositoryDocumentsPayload
} from "../api/repositoryDocuments"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { useT } from "../hooks/useT"

export function RepositoryDocumentsRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const documents = useQuery({
    queryKey: ["repositories", repositoryId, "documents"],
    queryFn: () => fetchRepositoryDocuments(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <main aria-label="Repository documents" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {documents.isPending ? <PanelMessage>
        {/* TODO: missing i18n key */}
        Loading repository documents...
      </PanelMessage> : null}
      {documents.isError ? <RepositoryDocumentsError error={documents.error} /> : null}
      {documents.isSuccess ? <RepositoryDocumentsView payload={documents.data} prefix={routePrefix(location.pathname)} /> : null}
    </main>
  )
}

function RepositoryDocumentsView({ payload, prefix }: { payload: RepositoryDocumentsPayload; prefix: string }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const queryKey = ["repositories", String(payload.repository.id), "documents"] as const
  const destroy = useMutation({
    mutationFn: (document: RepositoryDocument) => deleteRepositoryDocument(document.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || "Document removed.")
    }
  })

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <Link className="hover:underline" to={`${prefix}${payload.repository.repository_path}`}>{payload.repository.slug}</Link>
        </h1>
      </header>

      <RepositoryTabs active="documents" prefix={prefix} tabs={payload.tabs} />
      <p className="text-sm text-gray-600 dark:text-gray-400">
        {/* TODO: missing i18n key */}
        Supporting documents available to agent runs for this repository.
      </p>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete document.")}</PanelMessage> : null}

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            {/* TODO: missing i18n key */}
            Documentation
          </h2>
        </div>

        {payload.documents.length === 0 ? (
          <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
            {/* TODO: missing i18n key */}
            No supporting documents yet. Upload a file or link a Google Doc to give the agent extra context.
          </div>
        ) : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
            {payload.documents.map((document) => (
              <li className="py-3" key={document.id}>
                <div className="flex items-start gap-3">
                  <DocumentBadge document={document} />
                  <DocumentSummary document={document} />
                  <button
                    className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:text-gray-300 dark:disabled:text-gray-600"
                    disabled={destroy.isPending}
                    onClick={() => {
                      if (window.confirm("Delete this document?")) destroy.mutate(document)
                    }}
                    type="button"
                  >
                    {/* TODO: missing i18n key */}
                    Delete
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <DocumentForms acceptedTypes={payload.accepted_file_content_types} onNotice={setNotice} payload={payload} />
    </>
  )
}

function DocumentForms({
  payload,
  acceptedTypes,
  onNotice
}: {
  payload: RepositoryDocumentsPayload
  acceptedTypes: string[]
  onNotice: (message: string | null) => void
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const queryKey = ["repositories", String(payload.repository.id), "documents"] as const
  const [fileTitle, setFileTitle] = useState("")
  const [file, setFile] = useState<File | null>(null)
  const [docTitle, setDocTitle] = useState("")
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const save = useMutation({
    mutationFn: (input: RepositoryDocumentInput) => createRepositoryDocument(payload.repository.id, input),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setFileTitle("")
      setFile(null)
      setDocTitle("")
      setGoogleDocUrl("")
      onNotice(updated.message || "Document added.")
    }
  })

  function submitFile(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    save.mutate({ kind: "file", title: fileTitle, google_docs_url: "", file })
  }

  function submitGoogleDoc(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    save.mutate({ kind: "google_doc", title: docTitle, google_docs_url: googleDocUrl, file: null })
  }

  return (
    <section className="grid gap-4 md:grid-cols-2">
      {save.isError ? <div className="md:col-span-2"><PanelMessage tone="error">{errorMessage(save.error, "Unable to add document.")}</PanelMessage></div> : null}

      <form className="space-y-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4" onSubmit={submitFile}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
          {/* TODO: missing i18n key */}
          Upload a file
        </h2>
        <Field label="File title">
          <input className={inputClass()} onChange={(event) => setFileTitle(event.target.value)} placeholder="Optional; defaults to filename" type="text" value={fileTitle} />
        </Field>
        <Field label="File">
          <input accept={acceptedTypes.join(",")} className="block w-full text-sm text-gray-700 dark:text-gray-300" onChange={(event) => setFile(event.currentTarget.files?.[0] || null)} required type="file" />
        </Field>
        <button className={primaryButton()} disabled={save.isPending} type="submit">
          {save.isPending ? (
            <>
              {/* TODO: missing i18n key */}
              Uploading...
            </>
          ) : (
            <>
              {/* TODO: missing i18n key */}
              Upload
            </>
          )}
        </button>
      </form>

      <form className="space-y-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4" onSubmit={submitGoogleDoc}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
          {/* TODO: missing i18n key */}
          Link a Google Doc
        </h2>
        <Field label="URL">
          <input className={inputClass()} onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/..." required type="url" value={googleDocUrl} />
        </Field>
        <Field label="Document title">
          <input className={inputClass()} onChange={(event) => setDocTitle(event.target.value)} placeholder="Optional" type="text" value={docTitle} />
        </Field>
        <button className={primaryButton()} disabled={save.isPending} type="submit">
          {save.isPending ? (
            <>
              {/* TODO: missing i18n key */}
              Adding...
            </>
          ) : (
            <>
              {/* TODO: missing i18n key */}
              Add Google Doc
            </>
          )}
        </button>
      </form>
    </section>
  )
}

function DocumentBadge({ document }: { document: RepositoryDocument }) {
  const { t } = useT("settings")
  let label = "DOC"
  if (document.kind === "google_doc") label = "G"
  if (document.content_type?.startsWith("image/")) label = "IMG"
  if (document.content_type === "application/pdf") label = "PDF"

  return (
    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-xs font-semibold text-gray-600 dark:text-gray-400">
      {label}
    </div>
  )
}

function DocumentSummary({ document }: { document: RepositoryDocument }) {
  const { t } = useT("settings")
  return (
    <div className="min-w-0 flex-1">
      <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{document.title}</div>
      <div className="mt-1 break-all text-xs text-gray-500 dark:text-gray-400">
        {document.kind === "google_doc" && document.google_doc_url ? (
          <a className="text-blue-600 dark:text-blue-400 underline hover:no-underline" href={document.google_doc_url} rel="noopener" target="_blank">{document.google_doc_url}</a>
        ) : (
          <span>
            {document.filename || (
              <>
                {/* TODO: missing i18n key */}
                No file attached
              </>
            )}
            {document.byte_size ? ` · ${formatBytes(document.byte_size)}` : ""}
          </span>
        )}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {document.uploaded_by || (
          <>
            {/* TODO: missing i18n key */}
            Unknown
          </>
        )} · {new Date(document.created_at).toLocaleString()}
      </div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  const { t } = useT("settings")
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-1">{children}</div>
    </label>
  )
}

function RepositoryDocumentsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load repository documents.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const { t } = useT("settings")
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    success: "border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 shadow-sm focus:outline-blue-600"
}

function primaryButton() {
  return "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
