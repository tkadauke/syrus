import { useMutation } from "@tanstack/react-query"
import { type FormEvent, type RefObject, useMemo, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { type ChatMessageAttachmentInput, createChat } from "@app/api/chats"
import { Button } from "@app/components/Button"
import { CloseIcon } from "@app/components/CloseIcon"
import { ImageAnnotationModal, type Shape } from "@app/components/ImageAnnotationModal"
import { Modal } from "@app/components/Modal"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { resolveExampleResultBody } from "@app/pluginToolCards"
import type { ToolOwnerType, ToolPresentationEntry, ToolPresentationExample, ToolSourceType } from "@app/toolPresentationRegistry"
import { createToolCardJob } from "../api/toolCardJobs"
import { rendererTypeFor, type RendererType, type ViewportPresetId } from "../toolCardCatalogTypes"

// The Tool Card Catalog's "Discuss this card" feedback flow: capture a
// screenshot of the currently rendered example preview, let the operator
// annotate it by reusing the same ImageAnnotationModal BugReportButton.tsx
// already drives, collect a free-text prompt, then hand the whole bundle
// (screenshot + vector annotation shapes + structured tool/example
// metadata) to a brand new chat -- so the assistant on the other end never
// needs the operator to hand-paste JSON to know what card, example, and
// payload they're looking at.

type Html2Canvas = typeof import("html2canvas-pro").default

let html2canvasPromise: Promise<Html2Canvas> | null = null
function loadHtml2Canvas() {
  html2canvasPromise ||= import("html2canvas-pro").then((module) => module.default)
  return html2canvasPromise
}

export type ToolCardFeedbackMetadata = {
  tool_name: string
  canonical_name: string
  owner_type: ToolOwnerType
  owner_name: string
  source_type: ToolSourceType
  renderer_type: RendererType
  read_only: boolean
  selected_example_id: string
  selected_viewport_preset: ViewportPresetId
  input_payload: Record<string, unknown> | null
  result_body: string | null
  result_payload: unknown
  result_error: boolean
  catalog_deep_link: string
  annotations: Shape[]
}

export function buildToolCardFeedbackMetadata(
  entry: ToolPresentationEntry,
  example: ToolPresentationExample,
  viewportPresetId: ViewportPresetId,
  deepLink: string,
  annotations: Shape[] = []
): ToolCardFeedbackMetadata {
  return {
    tool_name: entry.displayLabel,
    canonical_name: entry.toolName,
    owner_type: entry.ownerType,
    owner_name: entry.ownerName,
    source_type: entry.sourceType,
    renderer_type: rendererTypeFor(entry),
    read_only: entry.readOnly,
    selected_example_id: example.id,
    selected_viewport_preset: viewportPresetId,
    input_payload: example.input ?? null,
    result_body: resolveExampleResultBody(example) || null,
    result_payload: example.parsedResult ?? null,
    result_error: Boolean(example.resultError),
    catalog_deep_link: deepLink,
    annotations
  }
}

// Folds the operator's free-text prompt and the structured metadata into
// one chat message body: a human-readable summary first (so the assistant's
// first read is plain language, not JSON), then the full metadata as a
// fenced JSON block so nothing is lost even if the summary omits a field --
// mirrors BugReports::ContextFormatter's "readable list + everything else"
// shape, just built client-side since this flow has no bug-report framing.
export function buildToolCardFeedbackPrompt(promptText: string, metadata: ToolCardFeedbackMetadata): string {
  const trimmedPrompt = promptText.trim()
  const heading = trimmedPrompt || `Discuss the "${metadata.tool_name}" tool card in the Tool Card Catalog.`

  const summary = [
    "---",
    "**Tool Card Context**",
    `- Tool: ${metadata.tool_name} (\`${metadata.canonical_name}\`)`,
    `- Owner: ${metadata.owner_type} · ${metadata.owner_name}`,
    `- Source: ${metadata.source_type}`,
    `- Renderer: ${metadata.renderer_type}`,
    `- Example: ${metadata.selected_example_id}`,
    `- Viewport: ${metadata.selected_viewport_preset}`,
    `- Result error: ${metadata.result_error ? "yes" : "no"}`,
    `- Catalog link: ${metadata.catalog_deep_link}`
  ].join("\n")

  const jsonBlock = "```json\n" + JSON.stringify(metadata, null, 2) + "\n```"

  return [heading, summary, jsonBlock].join("\n\n")
}

type ScreenshotState = { dataUrl: string; originalDataUrl: string; shapes: Shape[] }

export type ToolCardDiscussButtonProps = {
  deepLink: string
  entry: ToolPresentationEntry
  example: ToolPresentationExample
  previewRef: RefObject<HTMLElement | null>
  viewportPresetId: ViewportPresetId
}

export function ToolCardDiscussButton({ deepLink, entry, example, previewRef, viewportPresetId }: ToolCardDiscussButtonProps) {
  const { t } = useT("syrus_dev")
  const navigate = useNavigate()
  const location = useLocation()

  const [open, setOpen] = useState(false)
  const [capturing, setCapturing] = useState(false)
  const [captureError, setCaptureError] = useState<string | null>(null)
  const [screenshot, setScreenshot] = useState<ScreenshotState | null>(null)
  const [annotating, setAnnotating] = useState(false)
  const [promptText, setPromptText] = useState("")

  const startChat = useMutation({
    mutationFn: (input: { attachments: ChatMessageAttachmentInput[]; text: string }) => createChat({ attachments: input.attachments, text: input.text }),
    onSuccess: (payload) => {
      setOpen(false)
      navigate(withRoutePrefix(payload.redirect_to, routePrefix(location.pathname)))
    }
  })

  // Skips the chat round-trip entirely: same screenshot + prompt, but
  // lands directly as a direct Job so the operator doesn't have to relay
  // "yes, go ahead and do this" back to an assistant that already has
  // everything it needs.
  const createJob = useMutation({
    mutationFn: (input: { prompt: string; screenshot: { name: string; mimeType: string; dataUrl: string } | null }) =>
      createToolCardJob({ prompt: input.prompt, screenshot: input.screenshot }),
    onSuccess: (payload) => {
      setOpen(false)
      navigate(withRoutePrefix(payload.redirect_to, routePrefix(location.pathname)))
    }
  })

  const metadata = useMemo(
    () => buildToolCardFeedbackMetadata(entry, example, viewportPresetId, deepLink, screenshot?.shapes ?? []),
    [entry, example, viewportPresetId, deepLink, screenshot]
  )

  async function openDialog() {
    startChat.reset()
    createJob.reset()
    setPromptText("")
    setScreenshot(null)
    setCaptureError(null)
    setAnnotating(false)
    setOpen(true)
    setCapturing(true)

    try {
      const node = previewRef.current
      if (!node) throw new Error("Preview element is not mounted")

      const html2canvas = await loadHtml2Canvas()
      const canvas = await html2canvas(node, { useCORS: true })
      const dataUrl = canvas.toDataURL("image/png")
      setScreenshot({ dataUrl, originalDataUrl: dataUrl, shapes: [] })
    } catch (error) {
      console.error(error)
      setCaptureError(t("tool_cards.discuss.capture_failed"))
    } finally {
      setCapturing(false)
    }
  }

  function closeDialog() {
    setOpen(false)
    setAnnotating(false)
  }

  function applyAnnotation(annotatedDataUrl: string, shapes: Shape[]) {
    setScreenshot((current) => (current ? { ...current, dataUrl: annotatedDataUrl, shapes } : current))
    setAnnotating(false)
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const text = buildToolCardFeedbackPrompt(promptText, metadata)
    const attachments: ChatMessageAttachmentInput[] = screenshot
      ? [{ dataUrl: screenshot.dataUrl, mimeType: "image/png", name: `${entry.toolName}-tool-card.png` }]
      : []
    startChat.mutate({ attachments, text })
  }

  function createJobFromDialog() {
    const prompt = buildToolCardFeedbackPrompt(promptText, metadata)
    const screenshotInput = screenshot
      ? { dataUrl: screenshot.dataUrl, mimeType: "image/png", name: `${entry.toolName}-tool-card.png` }
      : null
    createJob.mutate({ prompt, screenshot: screenshotInput })
  }

  return (
    <>
      <Button onClick={() => void openDialog()} size="sm" type="button" variant="secondary">
        {t("tool_cards.discuss.trigger")}
      </Button>

      {open && annotating && screenshot ? (
        <ImageAnnotationModal
          dataUrl={screenshot.dataUrl}
          initialShapes={screenshot.shapes}
          name={`${entry.toolName}-tool-card.png`}
          onClose={() => setAnnotating(false)}
          onDone={applyAnnotation}
          originalDataUrl={screenshot.originalDataUrl}
        />
      ) : null}

      {open && !annotating ? (
        <Modal
          className="flex max-h-[calc(100vh-2rem)] w-full max-w-2xl flex-col gap-4 overflow-y-auto rounded-lg bg-surface p-5 shadow-xl"
          label={t("tool_cards.discuss.modal_aria", { tool: entry.displayLabel })}
          onClose={closeDialog}
          open
        >
          <form className="space-y-4" onSubmit={submit}>
            <div className="flex items-start justify-between gap-4">
              <h2 className="text-lg font-semibold text-text-primary">{t("tool_cards.discuss.heading", { tool: entry.displayLabel })}</h2>
              <button
                aria-label={t("tool_cards.discuss.close")}
                className="flex h-8 w-8 items-center justify-center rounded-lg text-text-secondary hover:bg-surface-raised"
                onClick={closeDialog}
                type="button"
              >
                <CloseIcon className="h-5 w-5" />
              </button>
            </div>

            {capturing ? <p className="text-sm text-text-secondary">{t("tool_cards.discuss.capturing")}</p> : null}
            {captureError ? (
              <p className="rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200" role="alert">
                {captureError}
              </p>
            ) : null}

            {screenshot ? (
              <div className="space-y-2">
                <img
                  alt={t("tool_cards.discuss.screenshot_alt", { tool: entry.displayLabel })}
                  className="max-h-64 w-full rounded border border-border object-contain"
                  src={screenshot.dataUrl}
                />
                <div className="flex justify-end">
                  <Button onClick={() => setAnnotating(true)} size="sm" type="button" variant="secondary">
                    {t("tool_cards.discuss.annotate")}
                  </Button>
                </div>
              </div>
            ) : null}

            <label className="block text-sm font-medium text-text-primary">
              {t("tool_cards.discuss.prompt_label")}
              <textarea
                className="mt-1 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text-primary focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand"
                onChange={(event) => setPromptText(event.target.value)}
                placeholder={t("tool_cards.discuss.prompt_placeholder")}
                rows={4}
                value={promptText}
              />
            </label>

            <details className="group rounded border border-border">
              <summary className="cursor-pointer list-none px-3 py-2 text-sm font-medium text-text-secondary hover:bg-surface-raised">
                {t("tool_cards.discuss.metadata_summary")}
              </summary>
              <pre className="max-h-48 overflow-auto border-t border-border px-3 py-2 text-xs text-text-secondary">
                {JSON.stringify(metadata, null, 2)}
              </pre>
            </details>

            {startChat.isError ? (
              <p className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300" role="alert">
                {errorMessage(startChat.error, t("tool_cards.discuss.chat_failed"))}
              </p>
            ) : null}
            {createJob.isError ? (
              <p className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300" role="alert">
                {errorMessage(createJob.error, t("tool_cards.discuss.job_failed"))}
              </p>
            ) : null}

            <div className="flex justify-end gap-2 border-t border-border pt-4">
              <Button onClick={closeDialog} type="button" variant="secondary">
                {t("tool_cards.discuss.cancel")}
              </Button>
              <Button
                disabled={startChat.isPending || createJob.isPending || capturing}
                onClick={createJobFromDialog}
                type="button"
                variant="secondary"
              >
                {createJob.isPending ? t("tool_cards.discuss.creating_job") : t("tool_cards.discuss.create_job")}
              </Button>
              <Button disabled={startChat.isPending || createJob.isPending || capturing} type="submit">
                {startChat.isPending ? t("tool_cards.discuss.starting") : t("tool_cards.discuss.submit")}
              </Button>
            </div>
          </form>
        </Modal>
      ) : null}
    </>
  )
}
