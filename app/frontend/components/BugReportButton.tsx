import { useMutation } from "@tanstack/react-query"
import type { FormEvent, KeyboardEvent } from "react"
import { useEffect, useState } from "react"
import { ApiError } from "../api/client"
import { createBugReport } from "../api/bugReports"
import { CloseIcon } from "./CloseIcon"
import { NoticeToast } from "./NoticeToast"

type Html2Canvas = typeof import("html2canvas-pro").default
type ScreenshotChoice = "viewport" | "fullPage" | "none"
type ScreenshotCapture = {
  file: File
  previewUrl: string
}
type ScreenshotCaptures = Partial<Record<Exclude<ScreenshotChoice, "none">, ScreenshotCapture>>

const MAX_FULL_PAGE_SCREENSHOT_PIXELS = 8_000_000

export function BugReportButton({ context }: { context: string }) {
  const [open, setOpen] = useState(false)
  const [capturing, setCapturing] = useState(false)
  const [capturingFullPage, setCapturingFullPage] = useState(false)
  const [title, setTitle] = useState("")
  const [description, setDescription] = useState("")
  const [captures, setCaptures] = useState<ScreenshotCaptures>({})
  const [screenshotChoice, setScreenshotChoice] = useState<ScreenshotChoice>("viewport")
  const [captureError, setCaptureError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const bugReport = useMutation({
    mutationFn: () => createBugReport({ title, description, screenshot: selectedScreenshot(captures, screenshotChoice) }),
    onSuccess: (payload) => {
      setOpen(false)
      setNotice(payload.message || "Bug report queued.")
      setTitle("")
      setDescription("")
      setCaptures({})
      setScreenshotChoice("viewport")
      setCaptureError(null)
    }
  })

  useEffect(() => () => revokeCaptures(captures), [captures])

  async function openDialog() {
    bugReport.reset()
    setTitle(`${context} bug`)
    setDescription("")
    setCaptures({})
    setScreenshotChoice("viewport")
    setCaptureError(null)
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
      setCaptureError("Screenshot capture failed. You can still create the bug report without one.")
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
      setCaptureError("Full-page screenshot is too large for this page. The viewport screenshot is still available.")
    } finally {
      setCapturingFullPage(false)
    }
  }

  function closeDialog() {
    bugReport.reset()
    setCaptures({})
    setCaptureError(null)
    setOpen(false)
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

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <button
        aria-label="Report a bug"
        className="fixed bottom-4 left-4 z-40 flex h-12 w-12 items-center justify-center rounded-full bg-rose-600 text-xl font-semibold text-white shadow-lg shadow-rose-900/20 hover:bg-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500 focus:ring-offset-2 disabled:cursor-wait disabled:opacity-60"
        disabled={capturing}
        onClick={() => void openDialog()}
        title="Report a bug"
        type="button"
      >
        <BugIcon />
      </button>
      {open ? (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <section aria-labelledby="bug-report-title" aria-modal="true" className="max-h-[calc(100vh-2rem)] w-full max-w-2xl overflow-y-auto rounded-lg bg-white shadow-xl" role="dialog">
            <form className="space-y-5 p-5 sm:p-6" onKeyDown={submitOnShortcut} onSubmit={submit}>
              <div className="flex items-start justify-between gap-4">
                <h2 className="text-lg font-semibold text-gray-900" id="bug-report-title">Report a bug</h2>
                <button
                  aria-label="Close"
                  className="flex h-10 w-10 items-center justify-center rounded-lg text-gray-500 hover:bg-gray-100 hover:text-gray-700 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
                  onClick={closeDialog}
                  type="button"
                >
                  <CloseIcon className="h-7 w-7" />
                </button>
              </div>

              <label className="block text-sm font-medium text-gray-700">
                Title
                <input
                  className="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  onChange={(event) => setTitle(event.target.value)}
                  required
                  type="text"
                  value={title}
                />
              </label>

              <label className="block text-sm font-medium text-gray-700">
                Description
                <textarea
                  className="mt-1 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  onChange={(event) => setDescription(event.target.value)}
                  rows={5}
                  value={description}
                />
              </label>

              <fieldset className="space-y-2">
                <legend className="text-sm font-medium text-gray-700">Screenshot</legend>
                {captureError ? (
                  <p className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">{captureError}</p>
                ) : null}
                <div className="grid gap-3 sm:grid-cols-3">
                  <ScreenshotOption
                    capture={captures.viewport}
                    choice="viewport"
                    label="Viewport"
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "viewport"}
                  />
                  <ScreenshotOption
                    capture={captures.fullPage}
                    choice="fullPage"
                    label={capturingFullPage ? "Capturing..." : "Full page"}
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "fullPage"}
                  />
                  <ScreenshotOption
                    choice="none"
                    label="No screenshot"
                    onChange={(choice) => void chooseScreenshot(choice)}
                    selected={screenshotChoice === "none"}
                  />
                </div>
              </fieldset>

              {bugReport.isError ? (
                <p className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700" role="alert">
                  {errorMessage(bugReport.error, "Bug report could not be queued.")}
                </p>
              ) : null}

              <div className="flex justify-end gap-2 border-t border-gray-100 pt-4">
                <button className="rounded-md border border-gray-300 px-3 py-1.5 text-sm text-gray-700 hover:bg-gray-50" onClick={closeDialog} type="button">
                  Cancel
                </button>
                <button className="rounded-md bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:bg-blue-300" disabled={bugReport.isPending} type="submit">
                  {bugReport.isPending ? "Creating..." : "Create Job"}
                </button>
              </div>
            </form>
          </section>
        </div>
      ) : null}
    </>
  )
}

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
  const borderClass = selected ? "border-blue-600 ring-2 ring-blue-600" : "border-gray-200 hover:border-gray-300"

  return (
    <label className={`flex cursor-pointer flex-col rounded-lg border bg-white p-2 ${borderClass}`}>
      <input
        aria-label={label}
        checked={selected}
        className="sr-only"
        name="bug-report-screenshot"
        onChange={() => onChange(choice)}
        type="radio"
      />
      {choice === "none" ? (
        <span className="flex aspect-video items-center justify-center rounded border border-dashed border-gray-200 bg-gray-50 text-sm font-semibold text-gray-500">None</span>
      ) : capture?.previewUrl ? (
        <img alt="" className="aspect-video w-full rounded border border-gray-100 object-cover" src={capture.previewUrl} />
      ) : (
        <span className="flex aspect-video items-center justify-center rounded border border-dashed border-gray-200 bg-gray-50 text-sm font-semibold text-gray-400">Unavailable</span>
      )}
      <span className="mt-2 text-sm font-semibold text-gray-900">{label}</span>
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

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
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

  if (width * height > MAX_FULL_PAGE_SCREENSHOT_PIXELS) {
    throw new Error(`Full-page screenshot is too large: ${width}x${height}`)
  }

  return html2canvas(document.body, {
    width,
    height,
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
