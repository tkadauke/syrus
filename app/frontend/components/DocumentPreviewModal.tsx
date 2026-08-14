import { useQuery } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { useT } from "../hooks/useT"
import { Markdown } from "../lib/Markdown"
import { CloseIcon } from "./CloseIcon"

// Generic file-preview popup for previewable documents (markdown/plain text
// and images) — modeled on chat's SourcePreviewModal (MessageCards.tsx). Only
// content types the caller has already classified as previewable should be
// passed in; PDFs, Office documents, and other binary files are meant to open
// directly in a new tab instead of being routed through this modal.

const MARKDOWN_CONTENT_TYPES = ["text/markdown", "text/x-markdown"]
const TEXT_CONTENT_TYPES = ["text/plain", ...MARKDOWN_CONTENT_TYPES]

export function isImageContentType(contentType: string | null | undefined): boolean {
  return !!contentType && contentType.startsWith("image/")
}

export function isPreviewableTextContentType(contentType: string | null | undefined): boolean {
  return !!contentType && TEXT_CONTENT_TYPES.includes(contentType)
}

export function isPreviewableContentType(contentType: string | null | undefined): boolean {
  return isImageContentType(contentType) || isPreviewableTextContentType(contentType)
}

export type PreviewableFile = {
  title: string
  rawUrl: string
  contentType: string | null
}

export function DocumentPreviewModal({ file, onClose }: { file: PreviewableFile; onClose: () => void }) {
  const { t } = useT("settings")
  const image = isImageContentType(file.contentType)
  const markdown = MARKDOWN_CONTENT_TYPES.includes(file.contentType || "")
  const [mode, setMode] = useState<"preview" | "source">("preview")

  const content = useQuery({
    queryKey: ["file_preview_content", file.rawUrl],
    queryFn: async () => {
      const response = await fetch(file.rawUrl, { credentials: "same-origin" })
      if (!response.ok) throw new Error(t("document_preview.error"))
      return response.text()
    },
    enabled: !image
  })

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  const showSource = !markdown || mode === "source"

  return (
    <div className="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/40 p-0 sm:items-center sm:p-4" onClick={onClose} role="presentation">
      <section
        aria-label={t("document_preview.aria_label", { title: file.title })}
        aria-modal="true"
        className="flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-white shadow-2xl sm:h-[min(82dvh,52rem)] sm:w-[min(92dvw,72rem)] sm:rounded-lg dark:bg-gray-950"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <header className="sticky top-0 z-10 flex shrink-0 items-center gap-3 border-b border-gray-200 bg-white px-4 py-3 dark:border-gray-800 dark:bg-gray-950">
          <h2 className="min-w-0 flex-1 truncate text-sm font-semibold text-gray-900 dark:text-gray-100">{file.title}</h2>
          {markdown ? (
            <div className="flex rounded border border-gray-200 p-0.5 text-xs dark:border-gray-700">
              <button className={`rounded px-2 py-1 ${mode === "preview" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 dark:text-gray-300"}`} onClick={() => setMode("preview")} type="button">{t("document_preview.preview")}</button>
              <button className={`rounded px-2 py-1 ${mode === "source" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 dark:text-gray-300"}`} onClick={() => setMode("source")} type="button">{t("document_preview.source")}</button>
            </div>
          ) : null}
          <a className="rounded border border-gray-200 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900" href={file.rawUrl} rel="noreferrer" target="_blank">{t("document_preview.open_raw")}</a>
          <button aria-label={t("document_preview.close")} className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-300 dark:hover:bg-gray-900 dark:hover:text-white" onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="min-h-0 flex-1 overflow-auto bg-gray-50 dark:bg-gray-900">
          {image ? (
            <div className="flex min-h-full items-center justify-center p-4">
              <img alt={file.title} className="max-h-full max-w-full rounded bg-white object-contain shadow dark:bg-gray-950" src={file.rawUrl} />
            </div>
          ) : content.isPending ? (
            <FilePreviewState message={t("document_preview.loading")} />
          ) : content.isError ? (
            <FilePreviewState message={t("document_preview.error")} tone="error" />
          ) : markdown && !showSource ? (
            <div className="mx-auto max-w-4xl bg-white px-5 py-4 dark:bg-gray-950">
              <Markdown className="text-gray-800 dark:text-gray-100" text={content.data ?? ""} />
            </div>
          ) : (
            <pre className="whitespace-pre-wrap break-words bg-white px-5 py-4 font-mono text-xs text-gray-900 dark:bg-gray-950 dark:text-gray-100" data-testid="file-preview-source">{content.data ?? ""}</pre>
          )}
        </div>
      </section>
    </div>
  )
}

function FilePreviewState({ message, tone = "neutral" }: { message: string; tone?: "neutral" | "error" }) {
  return <div className={`flex min-h-full items-center justify-center px-4 py-10 text-sm ${tone === "error" ? "text-red-600 dark:text-red-400" : "text-gray-500 dark:text-gray-400"}`}>{message}</div>
}
