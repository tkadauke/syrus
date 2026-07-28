import { useMutation } from "@tanstack/react-query"
import type { ChangeEvent, FormEvent, KeyboardEvent, ReactNode } from "react"
import { forwardRef, useEffect, useImperativeHandle, useRef, useState } from "react"
import { createBugReport } from "../api/bugReports"
import type { ChatMessageItem } from "../api/chats"
import { useT } from "../hooks/useT"
import { CloseIcon } from "./CloseIcon"
import { NoticeToast } from "./NoticeToast"
import { errorMessage } from "../lib/errorMessage"

type Html2Canvas = typeof import("html2canvas-pro").default
type ScreenshotChoice = "viewport" | "fullPage" | "none"
type ScreenshotCapture = {
  file: File
  previewUrl: string
}
type ScreenshotCaptures = Partial<Record<Exclude<ScreenshotChoice, "none">, ScreenshotCapture>>

const MAX_FULL_PAGE_SCREENSHOT_PIXELS = 8_000_000
const MAX_ATTACHMENT_SIZE = 20 * 1024 * 1024
const MAX_EXTRA_ATTACHMENTS = 9
const TRANSCRIPT_PREVIEW_MAX_CHARS = 300
const ACCEPTED_ATTACHMENT_TYPES = [
  "text/plain", "text/markdown", "text/x-markdown", "application/pdf",
  "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml",
  ".txt", ".md", ".markdown", ".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg"
].join(",")

export interface BugReportButtonHandle {
  open: (messages?: ChatMessageItem[]) => void
}

export const BugReportButton = forwardRef<BugReportButtonHandle, {
  bugReportMode?: "direct_job" | "github_issue" | null
  context: string
  position?: "bottom-left" | "bottom-right"
  reportIssueRepoSlug?: string | null
}>(function BugReportButton({ bugReportMode, context, position = "bottom-left", reportIssueRepoSlug }, ref) {
  const { t } = useT("common")
  const [open, setOpen] = useState(false)
  const [capturing, setCapturing] = useState(false)
  const [capturingFullPage, setCapturingFullPage] = useState(false)
  const [title, setTitle] = useState("")
  const [description, setDescription] = useState("")
  const [captures, setCaptures] = useState<ScreenshotCaptures>({})
  const [screenshotChoice, setScreenshotChoice] = useState<ScreenshotChoice>("viewport")
  const [captureError, setCaptureError] = useState<string | null>(null)
  const [attachments, setAttachments] = useState<File[]>([])
  const [attachmentError, setAttachmentError] = useState<string | null>(null)
  const [transcriptMessages, setTranscriptMessages] = useState<ChatMessageItem[]>([])
  const [includeTranscript, setIncludeTranscript] = useState(false)
  const [notice, setNotice] = useState<ReactNode>(null)

  // Always-current reference to openDialog so the imperative handle never closes
  // over a stale version of the function.
  const openDialogRef = useRef<((messages?: ChatMessageItem[]) => void) | null>(null)

  const bugReport = useMutation({
    mutationFn: () => {
      const allAttachments = [...attachments]
      if (includeTranscript && transcriptMessages.length > 0) {
        const text = serializeTranscript(transcriptMessages)
        if (text.trim().length > 0) {
          allAttachments.push(new File([text], "chat-transcript.txt", { type: "text/plain" }))
        }
      }
      return createBugReport({ title, description, screenshot: selectedScreenshot(captures, screenshotChoice), attachments: allAttachments })
    },
    onSuccess: (payload) => {
      setOpen(false)
      setTitle("")
      setDescription("")
      setCaptures({})
      setScreenshotChoice("viewport")
      setCaptureError(null)
      setAttachments([])
      setAttachmentError(null)
      setTranscriptMessages([])
      setIncludeTranscript(false)

      if (payload.issue_url) {
        const issueUrl = payload.issue_url
        setNotice(
          <span>
            {t("bug_report.filed")}{" "}
            <a className="underline hover:no-underline" href={issueUrl} rel="noreferrer" target="_blank">
              {t("bug_report.view_issue")}
            </a>
          </span>
        )
      } else {
        setNotice(payload.message || t("bug_report.queued"))
      }
    }
  })

  useEffect(() => () => revokeCaptures(captures), [captures])

  // Keep the ref up to date so the imperative handle always calls the latest openDialog.
  openDialogRef.current = (messages?: ChatMessageItem[]) => void openDialog(messages ?? [])

  useImperativeHandle(ref, () => ({
    open(messages?: ChatMessageItem[]) {
      openDialogRef.current?.(messages)
    }
  }), [])

  async function openDialog(withMessages: ChatMessageItem[] = []) {
    bugReport.reset()
    setTitle(`${context} bug`)
    setDescription("")
    setCaptures({})
    setScreenshotChoice("viewport")
    setCaptureError(null)
    setAttachments([])
    setAttachmentError(null)
    setTranscriptMessages(withMessages)
    setIncludeTranscript(false)
    setNotice(null)
    setCapturing(true)

    try {
      const html2canvas = await loadHtml2Canvas()
      const viewportCanvas = await captureViewport(html2canvas)
      const viewport = await canvasToCapture(viewportCanvas, "bug-report-viewport.png")

      setCaptures({ viewport })
    } catch (error) {
      console.error(error)
      setScreenshotChoice("none")
      setCaptureError(t("bug_report.screenshot_failed"))
    } finally {
      setCapturing(false)
      setOpen(true)
    }
  }

  async function chooseScreenshot(choice: ScreenshotChoice) {
    setScreenshotChoice(choice)

    if (choice !== "fullPage" || captures.fullPage || capturingFullPage) return

    setCaptureError(null)
    setCapturingFullPage(true)

    try {
      const html2canvas = await loadHtml2Canvas()
      const fullPageCanvas = await captureFullPage(html2canvas)
      const fullPage = await canvasToCapture(fullPageCanvas, "bug-report-full-page.png")
      setCaptures((current) => ({ ...current, fullPage }))
    } catch (error) {
      console.error(error)
      setScreenshotChoice(captures.viewport ? "viewport" : "none")
      setCaptureError(t("bug_report.full_page_failed"))
    } finally {
      setCapturingFullPage(false)
    }
  }

  function closeDialog() {
    bugReport.reset()
    setCaptures({})
    setCaptureError(null)
    setAttachments([])
    setAttachmentError(null)
    setTranscriptMessages([])
    setIncludeTranscript(false)
    setOpen(false)
  }

  function handleAttachmentChange(event: ChangeEvent<HTMLInputElement>) {
    const files = Array.from(event.target.files ?? [])
    event.target.value = ""

    const oversized = files.find((f) => f.size > MAX_ATTACHMENT_SIZE)
    if (oversized) {
      setAttachmentError(t("bug_report.attachments_too_large", { filename: oversized.name }))
      const valid = files.filter((f) => f.size <= MAX_ATTACHMENT_SIZE)
      if (valid.length > 0) {
        setAttachments((current) => [...current, ...valid].slice(0, MAX_EXTRA_ATTACHMENTS))
      }
      return
    }

    setAttachmentError(null)
    setAttachments((current) => {
      const combined = [...current, ...files]
      if (combined.length > MAX_EXTRA_ATTACHMENTS) {
        setAttachmentError(t("bug_report.attachments_max_reached"))
        return combined.slice(0, MAX_EXTRA_ATTACHMENTS)
      }
      return combined
    })
  }

  function removeAttachment(index: number) {
    setAttachments((current) => current.filter((_, i) => i !== index))
    setAttachmentError(null)
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    bugReport.mutate()
  }

  function submitOnShortcut(event: KeyboardEvent<HTMLFormElement>) {
    if (bugReport.isPending || event.key !== "Enter" || (!event.metaKey && !event.ctrlKey)) return

    event.preventDefault()
    event.currentTarget.requestSubmit()
  }

  const visibleTranscriptMessages = transcriptMessages.filter(
    (m) => (m.role === "user" || m.role === "assistant") && m.text.trim().length > 0
  )

  const isGitHubIssueMode = bugReportMode === "github_issue"
  const submitLabel = bugReport.isPending
    ? (isGitHubIssueMode ? t("bug_report.submitting_issue") : t("bug_report.submitting"))
    : (isGitHubIssueMode ? t("bug_report.submit_issue") : t("bug_report.submit"))

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <button
        aria-label={t("bug_report.title")}
        className={`fixed bottom-4 ${position === "bottom-right" ? "right-4" : "left-4"} z-40 hidden sm:flex h-12 w-12 items-center justify-center rounded-full bg-rose-600 text-xl font-semibold text-white shadow-lg shadow-rose-900/20 hover:bg-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500 focus:ring-offset-2 dark:focus:ring-offset-gray-950 disabled:cursor-wait disabled:opacity-60`}
        disabled={capturing}
        onClick={() => void openDialog()}
        title={t("bug_report.title")}
        type="button"
      >
        <BugIcon />
      </button>
      {open ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" data-html2canvas-ignore>
          <section aria-labelledby="bug-report-title" aria-modal="true" className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl" role="dialog">
            <form className="space-y-5 p-5 sm:p-6" onKeyDown={submitOnShortcut} onSubmit={submit}>
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="bug-report-title">{t("bug_report.title")}</h2>
                  {bugReportMode === "direct_job" ? (
                    <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{t("bug_report.mode_direct_job")}</p>
                  ) : bugReportMode === "github_issue" && reportIssueRepoSlug ? (
                    <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">{t("bug_report.mode_github_issue", { slug: reportIssueRepoSlug })}</p>
                  ) : null}
                </div>
                <button
                  aria-label={t("bug_report.close")}
                  className="flex h-10 w-10 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-gray-950"
                  onClick={closeDialog}
                  type="button"
                >
                  <CloseIcon className="h-7 w-7" />
                </button>
              </div>

              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                {t("bug_report.field_title")}
                <input
                  className="mt-1 w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  onChange={(event) => setTitle(event.target.value)}
                  required
                  type="text"
                  value={title}
                />
              </label>

              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                {t("bug_report.field_description")}
                <textarea
                  className="mt-1 w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  onChange={(event) => setDescription(event.target.value)}
                  rows={5}
                  value={description}
                />
              </label>

              <fieldset className="space-y-2">
                <legend className="text-sm font-medium text-gray-700 dark:text-gray-300">{t("bug_report.screenshot")}</legend>
                {captureError ? (
                  <p className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">{captureError}</p>
                ) : null}
                <div className="grid gap-3 sm:grid-cols-3">
                  <ScreenshotOption
                    capture={captures.viewport}
                    choice="viewport"
                    label={t("bug_report.viewport")}
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "viewport"}
                  />
                  <ScreenshotOption
                    capture={captures.fullPage}
                    choice="fullPage"
                    label={capturingFullPage ? t("bug_report.capturing") : t("bug_report.full_page")}
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "fullPage"}
                  />
                  <ScreenshotOption
                    choice="none"
                    label={t("bug_report.no_screenshot")}
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "none"}
                  />
                </div>
              </fieldset>

              <div className="space-y-2">
                <div className="flex items-center justify-between gap-4">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">{t("bug_report.attachments")}</span>
                  <label className={`cursor-pointer rounded-md border border-gray-300 dark:border-gray-600 px-2 py-1 text-xs text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800 ${attachments.length >= MAX_EXTRA_ATTACHMENTS ? "opacity-50 cursor-not-allowed" : ""}`}>
                    {t("bug_report.attachments_add")}
                    <input
                      accept={ACCEPTED_ATTACHMENT_TYPES}
                      className="sr-only"
                      disabled={attachments.length >= MAX_EXTRA_ATTACHMENTS}
                      multiple
                      onChange={handleAttachmentChange}
                      type="file"
                    />
                  </label>
                </div>
                <p className="text-xs text-gray-500 dark:text-gray-400">{t("bug_report.attachments_hint")}</p>
                {attachmentError ? (
                  <p className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">{attachmentError}</p>
                ) : null}
                {attachments.length > 0 ? (
                  <ul className="space-y-1">
                    {attachments.map((file, index) => (
                      <li className="flex items-center gap-2 rounded border border-gray-200 dark:border-gray-700 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300" key={index}>
                        <span className="min-w-0 flex-1 truncate">{file.name}</span>
                        <button
                          aria-label={t("bug_report.attachments_remove", { filename: file.name })}
                          className="flex-none text-gray-400 hover:text-gray-600 dark:hover:text-gray-200 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-1 rounded"
                          onClick={() => removeAttachment(index)}
                          type="button"
                        >
                          <CloseIcon className="h-4 w-4" />
                        </button>
                      </li>
                    ))}
                  </ul>
                ) : null}
              </div>

              {visibleTranscriptMessages.length > 0 ? (
                <div className="space-y-2">
                  <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300 cursor-pointer">
                    <input
                      checked={includeTranscript}
                      className="rounded border-gray-300 dark:border-gray-600 text-blue-600 focus:ring-blue-500"
                      onChange={(e) => setIncludeTranscript(e.target.checked)}
                      type="checkbox"
                    />
                    {t("bug_report.include_transcript")}
                  </label>
                  {includeTranscript ? (
                    <div aria-label={t("bug_report.transcript_preview")} className="max-h-48 overflow-y-auto rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 text-xs text-gray-600 dark:text-gray-400 space-y-3">
                      {visibleTranscriptMessages.map((m, i) => (
                        <div key={i}>
                          <div className="font-semibold text-gray-700 dark:text-gray-300">[{m.role === "user" ? "User" : "Assistant"}]</div>
                          <p className="mt-0.5 whitespace-pre-wrap font-mono">{truncateForPreview(m.text)}</p>
                        </div>
                      ))}
                    </div>
                  ) : null}
                </div>
              ) : null}

              {bugReport.isError ? (
                <p className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 px-3 py-2 text-sm text-red-700 dark:text-red-300" role="alert">
                  {errorMessage(bugReport.error, t("bug_report.error"))}
                </p>
              ) : null}

              <div className="flex justify-end gap-2 border-t border-gray-100 dark:border-gray-800 pt-4">
                <button className="rounded-md border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800" onClick={closeDialog} type="button">
                  {t("bug_report.cancel")}
                </button>
                <button className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={bugReport.isPending} type="submit">
                  {submitLabel}
                </button>
              </div>
            </form>
          </section>
        </div>
      ) : null}
    </>
  )
})

function ScreenshotOption({
  capture,
  choice,
  label,
  onChange,
  selected
}: {
  capture?: ScreenshotCapture
  choice: ScreenshotChoice
  label: string
  onChange: (choice: ScreenshotChoice) => void
  selected: boolean
}) {
  const { t } = useT("common")
  const borderClass = selected ? "border-blue-600 dark:border-blue-400 ring-2 ring-blue-600 dark:ring-blue-400" : "border-gray-200 dark:border-gray-700 hover:border-gray-300 dark:hover:border-gray-500"

  return (
    <label className={`flex cursor-pointer flex-col rounded-lg border bg-white dark:bg-gray-900 p-2 ${borderClass}`}>
      <input
        aria-label={label}
        checked={selected}
        className="sr-only"
        name="bug-report-screenshot"
        onChange={() => onChange(choice)}
        type="radio"
      />
      {choice === "none" ? (
        <span className="flex aspect-video items-center justify-center rounded border border-dashed border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-sm font-semibold text-gray-500 dark:text-gray-400">{t("bug_report.none")}</span>
      ) : capture?.previewUrl ? (
        <img alt="" className="aspect-video w-full rounded border border-gray-100 dark:border-gray-800 object-cover" src={capture.previewUrl} />
      ) : (
        <span className="flex aspect-video items-center justify-center rounded border border-dashed border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 text-sm font-semibold text-gray-400 dark:text-gray-500">{t("bug_report.unavailable")}</span>
      )}
      <span className="mt-2 text-sm font-semibold text-gray-900 dark:text-gray-100">{label}</span>
    </label>
  )
}

function BugIcon() {
  return (
    <svg aria-hidden="true" className="h-7 w-7" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2.25" viewBox="0 0 24 24">
      <path d="M9 9.5a3 3 0 0 1 6 0v6a3 3 0 0 1-6 0z" />
      <path d="M9 10h6" />
      <path d="M9 14h6" />
      <path d="M12 6.5v3" />
      <path d="m9.5 7-2-2" />
      <path d="m14.5 7 2-2" />
      <path d="M7 12H4" />
      <path d="M20 12h-3" />
      <path d="m7.5 16-2.5 2" />
      <path d="m16.5 16 2.5 2" />
    </svg>
  )
}


function selectedScreenshot(captures: ScreenshotCaptures, choice: ScreenshotChoice) {
  if (choice === "none") return null

  return captures[choice]?.file || null
}

let html2canvasPromise: Promise<Html2Canvas> | null = null

function loadHtml2Canvas() {
  html2canvasPromise ||= import("html2canvas-pro").then((module) => module.default)
  return html2canvasPromise
}

function captureViewport(html2canvas: Html2Canvas) {
  return html2canvas(document.body, {
    x: window.scrollX,
    y: window.scrollY,
    width: window.innerWidth,
    height: window.innerHeight,
    windowWidth: window.innerWidth,
    windowHeight: window.innerHeight,
    useCORS: true
  })
}

function captureFullPage(html2canvas: Html2Canvas) {
  const width = Math.max(
    document.body.scrollWidth,
    document.documentElement.scrollWidth,
    window.innerWidth
  )
  const height = Math.max(
    document.body.scrollHeight,
    document.documentElement.scrollHeight,
    window.innerHeight
  )
  const scale = Math.min(1, Math.sqrt(MAX_FULL_PAGE_SCREENSHOT_PIXELS / (width * height)))

  return html2canvas(document.body, {
    x: 0,
    y: 0,
    width,
    height,
    scrollX: 0,
    scrollY: 0,
    scale,
    windowWidth: width,
    windowHeight: height,
    useCORS: true
  })
}

function canvasToCapture(canvas: HTMLCanvasElement, filename: string) {
  return new Promise<ScreenshotCapture>((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error("canvas.toBlob returned null"))
        return
      }

      const file = new File([blob], filename, { type: "image/png" })
      resolve({
        file,
        previewUrl: typeof URL.createObjectURL === "function" ? URL.createObjectURL(file) : ""
      })
    }, "image/png")
  })
}

function revokeCaptures(captures: ScreenshotCaptures) {
  Object.values(captures).forEach((capture) => {
    if (capture?.previewUrl && typeof URL.revokeObjectURL === "function") {
      URL.revokeObjectURL(capture.previewUrl)
    }
  })
}

function serializeTranscript(messages: ChatMessageItem[]): string {
  return messages
    .filter((m) => (m.role === "user" || m.role === "assistant") && m.text.trim().length > 0)
    .map((m) => `[${m.role === "user" ? "User" : "Assistant"}]\n${m.text}`)
    .join("\n\n")
}

function truncateForPreview(text: string): string {
  if (text.length <= TRANSCRIPT_PREVIEW_MAX_CHARS) return text
  return text.slice(0, TRANSCRIPT_PREVIEW_MAX_CHARS) + "…"
}
