import { inputClass } from "../lib/formClasses"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { NoticeToast } from "../components/NoticeToast"
import {
  addCredentialDocuments,
  deleteCredentialDocument,
  fetchCredentialDocuments,
  type PersonalDocument,
  type PersonalDocumentsPayload
} from "../api/credentials"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { PanelMessage } from "../components/PanelMessage"
import { errorMessage } from "../lib/errorMessage"
import { formatBytes } from "../lib/format"

const queryKey = ["personal-documents"] as const

export function PersonalDocumentsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("personal_documents.heading"))
  const documents = useQuery({
    queryKey,
    queryFn: fetchCredentialDocuments
  })

  return (
    <main aria-label={t("aria_personal_documents")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">
          {t('personal_documents.heading')}
        </h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
          {t('personal_documents.description')}
        </p>
      </header>

      {documents.isPending ? <PanelMessage>
        {t('personal_documents.loading')}
      </PanelMessage> : null}
      {documents.isError ? <DocumentsError error={documents.error} /> : null}
      {documents.isSuccess ? <PersonalDocumentsView payload={documents.data} /> : null}
    </main>
  )
}

function PersonalDocumentsView({ payload }: { payload: PersonalDocumentsPayload }) {
  const { t } = useT("settings")
  const [notice, setNotice] = useState<string | null>(payload.message || null)

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <DocumentsPanel onNotice={setNotice} payload={payload} />
    </>
  )
}

function DocumentsPanel({ payload, onNotice }: { payload: PersonalDocumentsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [files, setFiles] = useState<File[]>([])
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const upload = useMutation({
    mutationFn: () => addCredentialDocuments(files, googleDocUrl),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setFiles([])
      setGoogleDocUrl("")
      onNotice(updated.message || t('personal_documents.added'))
    }
  })
  const destroy = useMutation({
    mutationFn: (document: PersonalDocument) => deleteCredentialDocument(document.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t('personal_documents.removed'))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    upload.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
            {t('personal_documents.section_heading')}
          </h2>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {t('personal_documents.attach_description')}
          </p>
        </div>
        <span className="text-xs text-gray-500 dark:text-gray-400">{payload.documents.length}</span>
      </div>

      <div className="mt-4 divide-y divide-gray-200 dark:divide-gray-700 rounded border border-gray-200 dark:border-gray-700">
        {payload.documents.length === 0 ? (
          <p className="p-4 text-sm text-gray-500 dark:text-gray-400">
            {t('personal_documents.empty')}
          </p>
        ) : payload.documents.map((document) => (
          <div className="flex items-center justify-between gap-3 p-3" key={document.id}>
            <DocumentSummary document={document} />
            <button
              className="text-xs font-medium text-red-600 dark:text-red-300 hover:text-red-700 dark:hover:text-red-300 disabled:text-red-300 dark:disabled:text-red-500"
              disabled={destroy.isPending}
              onClick={() => {
                if (window.confirm(t('personal_documents.confirm_delete'))) destroy.mutate(document)
              }}
              type="button"
            >
              {t('personal_documents.delete')}
            </button>
          </div>
        ))}
      </div>

      <form className="mt-4 space-y-3" onSubmit={submit}>
        {upload.isError ? <PanelMessage tone="error">{errorMessage(upload.error, "Unable to add document.")}</PanelMessage> : null}
        {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete document.")}</PanelMessage> : null}
        <Field label={t('personal_documents.upload_files')}>
          <input
            className="block w-full text-sm text-gray-700 dark:text-gray-300"
            multiple
            onChange={(event) => setFiles(Array.from(event.currentTarget.files || []))}
            type="file"
          />
        </Field>
        <Field label={t('personal_documents.google_doc_url')}>
          <input className={inputClass()} onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/d/..." type="url" value={googleDocUrl} />
        </Field>
        <button className="rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 disabled:bg-gray-400" disabled={upload.isPending} type="submit">
          {upload.isPending ? (
            <>
              {t('personal_documents.adding')}
            </>
          ) : (
            <>
              {t('personal_documents.add')}
            </>
          )}
        </button>
      </form>
    </section>
  )
}

function DocumentSummary({ document }: { document: PersonalDocument }) {
  const { t } = useT("settings")
  if (document.kind === "google_doc" && document.google_doc_url) {
    return (
      <div className="min-w-0">
        <a className="block truncate text-sm font-medium text-blue-700 dark:text-blue-300 hover:underline" href={document.google_doc_url} rel="noopener" target="_blank">{document.google_doc_url}</a>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
          {t('personal_documents.google_doc')}
        </div>
      </div>
    )
  }

  return (
    <div className="min-w-0">
      <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">
        {document.filename || (
          <>
            {t('personal_documents.file')}
          </>
        )}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{document.content_type || "unknown"} · {formatBytes(document.byte_size)}</div>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  const { t } = useT("settings")
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function DocumentsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load personal documents.")}</PanelMessage>
}


