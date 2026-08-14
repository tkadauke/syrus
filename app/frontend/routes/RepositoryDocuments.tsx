import { inputClass } from "../lib/formClasses"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { routePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
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
import { PanelMessage } from "../components/PanelMessage"
import { errorMessage } from "../lib/errorMessage"
import { formatBytes } from "../lib/format"
import { useConfirm } from "../hooks/useConfirm"
import { DocumentPreviewModal, isPreviewableContentType } from "../components/DocumentPreviewModal"

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
    <main aria-label={t("aria_repo_documents")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {documents.isPending ? <PanelMessage>
        {t('repository_documents.loading')}
      </PanelMessage> : null}
      {documents.isError ? <RepositoryDocumentsError error={documents.error} /> : null}
      {documents.isSuccess ? <RepositoryDocumentsView payload={documents.data} prefix={routePrefix(location.pathname)} /> : null}
    </main>
  )
}

function RepositoryDocumentsView({ payload, prefix }: { payload: RepositoryDocumentsPayload; prefix: string }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const [previewDocument, setPreviewDocument] = useState<RepositoryDocument | null>(null)
  const queryKey = ["repositories", String(payload.repository.id), "documents"] as const
  const destroy = useMutation({
    mutationFn: (document: RepositoryDocument) => deleteRepositoryDocument(document.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || t('repository_documents.removed'))
    }
  })

  function openDocument(document: RepositoryDocument) {
    if (document.kind === "google_doc") {
      if (document.google_doc_url) window.open(document.google_doc_url, "_blank", "noopener")
      return
    }
    if (!document.file_path) return
    if (isPreviewableContentType(document.content_type)) {
      setPreviewDocument(document)
    } else {
      window.open(document.file_path, "_blank", "noopener")
    }
  }

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <Link className="hover:underline" to={`${prefix}${payload.repository.repository_path}`}>{payload.repository.slug}</Link>
        </h1>
      </header>

      <RepositoryTabs active="documents" prefix={prefix} tabs={payload.tabs} />
      <p className="text-sm text-gray-600 dark:text-gray-400">
        {t('repository_documents.description')}
      </p>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete document.")}</PanelMessage> : null}

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            {t('repository_documents.documentation')}
          </h2>
        </div>

        {payload.documents.length === 0 ? (
          <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
            {t('repository_documents.empty')}
          </div>
        ) : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
            {payload.documents.map((document) => (
              <li className="py-3" key={document.id}>
                <div className="flex items-start gap-3">
                  <button
                    className="flex min-w-0 flex-1 items-start gap-3 rounded text-left hover:bg-gray-50 dark:hover:bg-gray-800"
                    onClick={() => openDocument(document)}
                    type="button"
                  >
                    <DocumentBadge document={document} />
                    <DocumentSummary document={document} />
                  </button>
                  <button
                    className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:text-gray-300 dark:disabled:text-gray-600"
                    disabled={destroy.isPending}
                    onClick={async () => {
                      if (await confirm({ message: t('repository_documents.confirm_delete'), destructive: true })) destroy.mutate(document)
                    }}
                    type="button"
                  >
                    {t('repository_documents.delete')}
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>

      <DocumentForms acceptedTypes={payload.accepted_file_content_types} onNotice={setNotice} payload={payload} />
      {previewDocument && previewDocument.file_path ? (
        <DocumentPreviewModal
          file={{ title: previewDocument.title, rawUrl: previewDocument.file_path, contentType: previewDocument.content_type }}
          onClose={() => setPreviewDocument(null)}
        />
      ) : null}
      {dialog}
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
          {t('repository_documents.upload_file')}
        </h2>
        <Field label="File title">
          <input className={inputClass()} onChange={(event) => setFileTitle(event.target.value)} placeholder={t("repository_documents.placeholder_optional_filename")} type="text" value={fileTitle} />
        </Field>
        <Field label="File">
          <input accept={acceptedTypes.join(",")} className="block w-full text-sm text-gray-700 dark:text-gray-300" onChange={(event) => setFile(event.currentTarget.files?.[0] || null)} required type="file" />
        </Field>
        <button className={primaryButton()} disabled={save.isPending} type="submit">
          {save.isPending ? (
            <>
              {t('repository_documents.uploading')}
            </>
          ) : (
            <>
              {t('repository_documents.upload')}
            </>
          )}
        </button>
      </form>

      <form className="space-y-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4" onSubmit={submitGoogleDoc}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
          {t('repository_documents.link_google_doc')}
        </h2>
        <Field label="URL">
          <input className={inputClass()} onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/..." required type="url" value={googleDocUrl} />
        </Field>
        <Field label="Document title">
          <input className={inputClass()} onChange={(event) => setDocTitle(event.target.value)} placeholder={t("repository_documents.placeholder_optional")} type="text" value={docTitle} />
        </Field>
        <button className={primaryButton()} disabled={save.isPending} type="submit">
          {save.isPending ? (
            <>
              {t('repository_documents.adding')}
            </>
          ) : (
            <>
              {t('repository_documents.add_google_doc')}
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
          <span className="text-blue-600 dark:text-blue-400 underline">{document.google_doc_url}</span>
        ) : (
          <span>
            {document.filename || (
              <>
                {t('repository_documents.no_file_attached')}
              </>
            )}
            {document.byte_size ? ` · ${formatBytes(document.byte_size)}` : ""}
          </span>
        )}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {document.uploaded_by || (
          <>
            {t('repository_documents.unknown')}
          </>
        )} · <RelativeTimestamp value={document.created_at} />
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


function primaryButton() {
  return "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
}


