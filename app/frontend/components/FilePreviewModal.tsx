import { useEffect, useRef, useState } from "react"
import { CloseIcon } from "./CloseIcon"
import { Markdown } from "../lib/Markdown"
import { highlightCode, inferToolResultLanguage } from "../lib/syntaxHighlight"
import { errorMessage } from "../lib/errorMessage"
import { useT } from "../hooks/useT"

// Shared file-preview popup used by both chat (source links the agent
// references from a local workspace) and Job detail attachments — same
// markdown/source rendering, "Open raw" link, and layout, fed by whatever
// content-fetching query the caller already has.
export type FilePreviewContent = { content: string | null; binary: boolean; too_large: boolean }

export type FilePreviewQuery = {
  isPending: boolean
  isError: boolean
  error: unknown
  data: FilePreviewContent | undefined
}

export function isMarkdownPath(path: string) {
  return /\.(md|markdown|mdown|mkdn)$/i.test(path)
}

export function FilePreviewModal({
  path,
  line = null,
  rawHref,
  query,
  unavailableMessage,
  onClose
}: {
  path: string
  line?: number | null
  rawHref: string
  query: FilePreviewQuery
  unavailableMessage?: string | null
  onClose: () => void
}) {
  const { t } = useT("common")
  const [mode, setMode] = useState<"preview" | "source">("preview")
  const bodyRef = useRef<HTMLDivElement>(null)
  const markdown = isMarkdownPath(path)
  const showSource = !markdown || mode === "source"
  const title = line ? `${path}:${line}` : path

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose()
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  useEffect(() => {
    if (!line || showSource === false || !query.data) return
    const row = bodyRef.current?.querySelector(`[data-source-line="${line}"]`)
    row?.scrollIntoView({ block: "center" })
  }, [query.data, line, showSource])

  return (
    <div className="fixed inset-0 z-50 flex h-[100dvh] w-[100dvw] items-stretch justify-center bg-gray-950/40 p-0 sm:items-center sm:p-4" onClick={onClose} role="presentation">
      <section
        aria-label={t("file_preview.dialog_label", { title })}
        aria-modal="true"
        className="flex h-[100dvh] w-[100dvw] flex-col overflow-hidden bg-white shadow-2xl sm:h-[min(82dvh,52rem)] sm:w-[min(92dvw,72rem)] sm:rounded-lg dark:bg-gray-950"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <header className="sticky top-0 z-10 flex shrink-0 items-center gap-3 border-b border-gray-200 bg-white px-4 py-3 dark:border-gray-800 dark:bg-gray-950">
          <div className="min-w-0 flex-1">
            <h2 className="truncate font-mono text-sm font-semibold text-gray-900 dark:text-gray-100">{path}</h2>
            {line ? <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{t("file_preview.line", { line })}</p> : null}
          </div>
          {markdown ? (
            <div className="flex rounded border border-gray-200 p-0.5 text-xs dark:border-gray-700">
              <button className={`rounded px-2 py-1 ${mode === "preview" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 dark:text-gray-300"}`} onClick={() => setMode("preview")} type="button">{t("file_preview.mode_preview")}</button>
              <button className={`rounded px-2 py-1 ${mode === "source" ? "bg-gray-900 text-white dark:bg-gray-100 dark:text-gray-900" : "text-gray-600 dark:text-gray-300"}`} onClick={() => setMode("source")} type="button">{t("file_preview.mode_source")}</button>
            </div>
          ) : null}
          <a className="rounded border border-gray-200 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-900" href={rawHref} rel="noreferrer" target="_blank">{t("file_preview.open_raw")}</a>
          <button aria-label={t("file_preview.close")} className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-300 dark:hover:bg-gray-900 dark:hover:text-white" onClick={onClose} type="button">
            <CloseIcon className="h-4 w-4" />
          </button>
        </header>
        <div className="min-h-0 flex-1 overflow-auto" ref={bodyRef}>
          {unavailableMessage ? (
            <FilePreviewState message={unavailableMessage} />
          ) : query.isPending ? (
            <FilePreviewState message={t("file_preview.loading")} />
          ) : query.isError ? (
            <FilePreviewState tone="error" message={errorMessage(query.error, t("file_preview.load_error"))} />
          ) : query.data!.binary ? (
            <FilePreviewState message={t("file_preview.binary")} />
          ) : query.data!.too_large ? (
            <FilePreviewState message={t("file_preview.too_large")} />
          ) : markdown && !showSource ? (
            <div className="mx-auto max-w-4xl px-5 py-4">
              <Markdown className="text-gray-800 dark:text-gray-100" text={query.data!.content ?? ""} />
            </div>
          ) : (
            <SourceCodeTable content={query.data!.content ?? ""} path={path} targetLine={line} />
          )}
        </div>
      </section>
    </div>
  )
}

function FilePreviewState({ message, tone = "neutral" }: { message: string; tone?: "neutral" | "error" }) {
  return <div className={`flex min-h-full items-center justify-center px-4 py-10 text-sm ${tone === "error" ? "text-red-600 dark:text-red-400" : "text-gray-500 dark:text-gray-400"}`}>{message}</div>
}

function SourceCodeTable({ content, path, targetLine }: { content: string; path: string; targetLine: number | null }) {
  const language = inferToolResultLanguage(path, "Read")
  const lines = content.split("\n")

  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid="source-preview-code">
      <tbody>
        {lines.map((line, index) => {
          const lineNum = index + 1
          const targeted = targetLine === lineNum
          return (
            <tr className={targeted ? "bg-yellow-100 dark:bg-yellow-950/50" : "bg-white dark:bg-gray-950"} data-source-line={lineNum} key={lineNum}>
              <td className="w-12 select-none border-r border-gray-100 px-2 py-0.5 text-right text-xs text-gray-400 dark:border-gray-800 dark:text-gray-600">{lineNum}</td>
              <td className="min-w-[40rem] whitespace-pre px-3 py-0.5 leading-relaxed text-gray-900 dark:text-gray-100">
                {language ? highlightCode(line || " ", language) : line || " "}
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}
