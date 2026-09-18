import { useMutation } from "@tanstack/react-query"
import { type FormEvent, type RefObject, useMemo, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { type ChatMessageAttachmentInput, createChat } from "@app/api/chats"
import { Button } from "@app/components/Button"
import { CloseIcon } from "@app/components/CloseIcon"
import { ImageAnnotationModal, type Shape } from "@app/components/ImageAnnotationModal"
import { Modal } from "@app/components/Modal"
import { Textarea } from "@app/components/Textarea"
import { Notice } from "@app/components/ui"
import { errorMessage } from "@app/lib/errorMessage"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"

type Html2Canvas = typeof import("html2canvas-pro").default

let html2canvasPromise: Promise<Html2Canvas> | null = null
function loadHtml2Canvas() {
  html2canvasPromise ||= import("html2canvas-pro").then((module) => module.default)
  return html2canvasPromise
}

export type CatalogFeedbackMetadata = { annotations: Shape[] }

type ScreenshotState = { dataUrl: string; originalDataUrl: string; shapes: Shape[] }

export type CatalogFeedbackDialogCopy = {
  trigger: string
  modalAria: string
  heading: string
  close: string
  capturing: string
  captureFailed: string
  screenshotAlt: string
  annotate: string
  promptLabel: string
  promptPlaceholder: string
  metadataSummary: string
  chatFailed: string
  cancel: string
  submit: string
  starting: string
}

export type CatalogFeedbackDialogProps<Metadata extends CatalogFeedbackMetadata> = {
  attachmentName: string
  buildMetadata: (annotations: Shape[]) => Metadata
  buildPrompt: (promptText: string, metadata: Metadata) => string
  copy: CatalogFeedbackDialogCopy
  previewRef: RefObject<HTMLElement | null>
}

export function CatalogFeedbackDialog<Metadata extends CatalogFeedbackMetadata>({
  attachmentName,
  buildMetadata,
  buildPrompt,
  copy,
  previewRef
}: CatalogFeedbackDialogProps<Metadata>) {
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

  const metadata = useMemo(() => buildMetadata(screenshot?.shapes ?? []), [buildMetadata, screenshot])

  async function openDialog() {
    startChat.reset()
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
      setCaptureError(copy.captureFailed)
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
    const text = buildPrompt(promptText, metadata)
    const attachments: ChatMessageAttachmentInput[] = screenshot
      ? [{ dataUrl: screenshot.dataUrl, mimeType: "image/png", name: attachmentName }]
      : []
    startChat.mutate({ attachments, text })
  }

  return (
    <>
      <Button onClick={() => void openDialog()} size="sm" type="button" variant="secondary">
        {copy.trigger}
      </Button>

      {open && annotating && screenshot ? (
        <ImageAnnotationModal
          dataUrl={screenshot.dataUrl}
          initialShapes={screenshot.shapes}
          name={attachmentName}
          onClose={() => setAnnotating(false)}
          onDone={applyAnnotation}
          originalDataUrl={screenshot.originalDataUrl}
        />
      ) : null}

      {open && !annotating ? (
        <Modal
          className="flex max-h-[calc(100vh-2rem)] w-full max-w-2xl flex-col gap-4 overflow-y-auto rounded-lg bg-surface p-5 shadow-xl"
          label={copy.modalAria}
          onClose={closeDialog}
          open
        >
          <form className="space-y-4" onSubmit={submit}>
            <div className="flex items-start justify-between gap-4">
              <h2 className="text-lg font-semibold text-text-primary">{copy.heading}</h2>
              <button
                aria-label={copy.close}
                className="flex h-8 w-8 items-center justify-center rounded-lg text-text-secondary hover:bg-surface-raised"
                onClick={closeDialog}
                type="button"
              >
                <CloseIcon className="h-5 w-5" />
              </button>
            </div>

            {capturing ? <p className="text-sm text-text-secondary">{copy.capturing}</p> : null}
            {captureError ? (
              <Notice role="alert" tone="warning">
                {captureError}
              </Notice>
            ) : null}

            {screenshot ? (
              <div className="space-y-2">
                <img
                  alt={copy.screenshotAlt}
                  className="max-h-64 w-full rounded border border-border object-contain"
                  src={screenshot.dataUrl}
                />
                <div className="flex justify-end">
                  <Button onClick={() => setAnnotating(true)} size="sm" type="button" variant="secondary">
                    {copy.annotate}
                  </Button>
                </div>
              </div>
            ) : null}

            <label className="block text-sm font-medium text-text-primary">
              {copy.promptLabel}
              <Textarea
                className="mt-1"
                onChange={(event) => setPromptText(event.target.value)}
                placeholder={copy.promptPlaceholder}
                rows={4}
                value={promptText}
              />
            </label>

            <details className="group rounded border border-border">
              <summary className="cursor-pointer list-none px-3 py-2 text-sm font-medium text-text-secondary hover:bg-surface-raised">
                {copy.metadataSummary}
              </summary>
              <pre className="max-h-48 overflow-auto border-t border-border px-3 py-2 text-xs text-text-secondary">
                {JSON.stringify(metadata, null, 2)}
              </pre>
            </details>

            {startChat.isError ? (
              <Notice role="alert" tone="danger">
                {errorMessage(startChat.error, copy.chatFailed)}
              </Notice>
            ) : null}

            <div className="flex justify-end gap-2 border-t border-border pt-4">
              <Button onClick={closeDialog} type="button" variant="secondary">
                {copy.cancel}
              </Button>
              <Button disabled={startChat.isPending || capturing} type="submit">
                {startChat.isPending ? copy.starting : copy.submit}
              </Button>
            </div>
          </form>
        </Modal>
      ) : null}
    </>
  )
}
