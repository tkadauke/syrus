import { useMutation } from "@tanstack/react-query"
import { type FormEvent, type RefObject, useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import { createEmptyChat, sendChatMessage, uploadChatAttachment } from "@app/api/chats"
import { Button } from "@app/components/Button"
import { type Shape, ImageAnnotationModal } from "@app/components/ImageAnnotationModal"
import { Modal } from "@app/components/Modal"
import { Textarea } from "@app/components/Textarea"
import { Notice } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { reportHandledError } from "@app/lib/handledErrorReporting"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import type { WorkbenchDefinition } from "../api/workbench"
import type { FixtureState } from "./fixtures"
import type { MotionSetting, ViewportId } from "./search"

// "Discuss with an agent": captures what the operator is looking at -- the
// definition, fixture state, viewport, motion/audio settings, deep link, a
// screenshot of the preview frame and optional annotations -- plus their
// prompt, and starts a chat with that as structured context. It is built on the
// public chat API the host exposes to every plugin; nothing here is shared with
// another plugin's catalog tooling.

export type DiscussionContext = {
  definition: Pick<
    WorkbenchDefinition,
    "key" | "version" | "scope" | "category" | "rarity" | "trigger" | "evaluator" | "visibility" | "implementation_status" | "presentation"
  >
  fixture_state: FixtureState
  viewport: { id: ViewportId; width: number }
  motion: MotionSetting
  audio: { supported: boolean; enabled: boolean }
  deep_link: string
  screenshot: { attached: boolean; error: string | null }
  annotations: Shape[]
}

export type DiscussionInput = {
  definition: WorkbenchDefinition
  fixtureState: FixtureState
  viewport: { id: ViewportId; width: number }
  motion: MotionSetting
  audio: { supported: boolean; enabled: boolean }
  deepLink: string
}

export function buildDiscussionContext(
  input: DiscussionInput,
  screenshot: { attached: boolean; error: string | null },
  annotations: Shape[] = []
): DiscussionContext {
  const { definition } = input
  return {
    definition: {
      key: definition.key,
      version: definition.version,
      scope: definition.scope,
      category: definition.category,
      rarity: definition.rarity,
      trigger: definition.trigger,
      evaluator: definition.evaluator,
      visibility: definition.visibility,
      implementation_status: definition.implementation_status,
      presentation: definition.presentation
    },
    fixture_state: input.fixtureState,
    viewport: input.viewport,
    motion: input.motion,
    audio: input.audio,
    deep_link: input.deepLink,
    screenshot,
    annotations
  }
}

// Plain-language summary first, then the full structured context as fenced
// JSON, so nothing is lost if the summary omits a field.
export function buildDiscussionPrompt(promptText: string, context: DiscussionContext): string {
  const heading = promptText.trim() || `Discuss the "${context.definition.key}" achievement in the Achievements workbench.`
  const summary = [
    "---",
    "**Achievements Workbench Context**",
    `- Definition: ${context.definition.key} (v${context.definition.version})`,
    `- Scope: ${context.definition.scope} · Category: ${context.definition.category} · Rarity: ${context.definition.rarity}`,
    `- Implementation: ${context.definition.implementation_status}`,
    `- Fixture state: ${context.fixture_state}`,
    `- Viewport: ${context.viewport.id} (${context.viewport.width}px)`,
    `- Motion: ${context.motion}`,
    `- Audio: ${context.audio.supported ? (context.audio.enabled ? "enabled" : "disabled") : "not supported yet"}`,
    `- Screenshot: ${context.screenshot.attached ? "attached" : `not attached${context.screenshot.error ? ` (${context.screenshot.error})` : ""}`}`,
    `- Workbench link: ${context.deep_link}`
  ].join("\n")
  return [heading, summary, "```json\n" + JSON.stringify(context, null, 2) + "\n```"].join("\n\n")
}

type Html2Canvas = typeof import("html2canvas-pro").default
let html2canvasPromise: Promise<Html2Canvas> | null = null
const loadHtml2Canvas = () => (html2canvasPromise ||= import("html2canvas-pro").then((module) => module.default))

type Screenshot = { dataUrl: string; originalDataUrl: string; shapes: Shape[] }

type Props = {
  input: DiscussionInput
  previewRef: RefObject<HTMLElement | null>
}

export function DiscussDialog({ input, previewRef }: Props) {
  const { t } = useT("achievements")
  const navigate = useNavigate()
  const location = useLocation()
  const [open, setOpen] = useState(false)
  const [capturing, setCapturing] = useState(false)
  const [captureError, setCaptureError] = useState<string | null>(null)
  const [screenshot, setScreenshot] = useState<Screenshot | null>(null)
  const [annotating, setAnnotating] = useState(false)
  const [promptText, setPromptText] = useState("")
  const attachmentName = `${input.definition.key}-workbench.png`

  const context = buildDiscussionContext(input, { attached: Boolean(screenshot), error: captureError }, screenshot?.shapes ?? [])

  const startChat = useMutation({
    mutationFn: async () => {
      const created = await createEmptyChat()
      const attachments = screenshot
        ? await fetch(screenshot.dataUrl)
            .then((response) => response.blob())
            .then((blob) => uploadChatAttachment(created.chat.id, new File([blob], attachmentName, { type: "image/png" })))
            .then((attachment) => [{ id: attachment.id, name: attachment.name, mimeType: attachment.mime_type, size: attachment.size, url: attachment.url }])
        : []
      await sendChatMessage(`/api/v1/app/chats/${created.chat.id}/message`, buildDiscussionPrompt(promptText, context), attachments)
      return created
    },
    onSuccess: (payload) => {
      setOpen(false)
      navigate(withRoutePrefix(payload.redirect_to, routePrefix(location.pathname)))
    }
  })

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
      const canvas = await (await loadHtml2Canvas())(node, { useCORS: true })
      const dataUrl = canvas.toDataURL("image/png")
      setScreenshot({ dataUrl, originalDataUrl: dataUrl, shapes: [] })
    } catch (error) {
      // The discussion still works without a screenshot: the context records
      // that none was attached and why.
      reportHandledError(error, { surface: "achievements", operation: "capture_workbench_screenshot", stage: "capture", recoverability: "non_retryable" })
      setCaptureError(t("workbench.discuss.capture_failed"))
    } finally {
      setCapturing(false)
    }
  }

  function applyAnnotation(blob: Blob, shapes: Shape[]) {
    const reader = new FileReader()
    reader.addEventListener("load", () => {
      if (typeof reader.result !== "string") return
      setScreenshot((current) => (current ? { ...current, dataUrl: reader.result as string, shapes } : current))
      setAnnotating(false)
    })
    reader.readAsDataURL(blob)
  }

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    startChat.mutate()
  }

  return (
    <>
      <Button onClick={() => void openDialog()} size="sm" type="button" variant="secondary">
        {t("workbench.discuss.trigger")}
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
          label={t("workbench.discuss.modal_aria", { key: input.definition.key })}
          onClose={() => setOpen(false)}
          open
        >
          <form className="space-y-4" onSubmit={submit}>
            <h2 className="text-lg font-semibold text-text-primary">{t("workbench.discuss.heading", { key: input.definition.key })}</h2>
            {capturing ? <p className="text-sm text-text-secondary">{t("workbench.discuss.capturing")}</p> : null}
            {captureError ? (
              <Notice role="alert" tone="warning">
                {captureError}
              </Notice>
            ) : null}
            {screenshot ? (
              <div className="space-y-2">
                <img
                  alt={t("workbench.discuss.screenshot_alt", { key: input.definition.key })}
                  className="max-h-64 w-full rounded border border-border object-contain"
                  src={screenshot.dataUrl}
                />
                <div className="flex justify-end">
                  <Button onClick={() => setAnnotating(true)} size="sm" type="button" variant="secondary">
                    {t("workbench.discuss.annotate")}
                  </Button>
                </div>
              </div>
            ) : null}
            <label className="block text-sm font-medium text-text-primary">
              {t("workbench.discuss.prompt_label")}
              <Textarea
                className="mt-1"
                onChange={(event) => setPromptText(event.target.value)}
                placeholder={t("workbench.discuss.prompt_placeholder")}
                rows={4}
                value={promptText}
              />
            </label>
            <details className="rounded border border-border">
              <summary className="cursor-pointer px-3 py-2 text-sm font-medium text-text-secondary">{t("workbench.discuss.context_summary")}</summary>
              <pre className="max-h-48 overflow-auto border-t border-border px-3 py-2 text-xs text-text-secondary">{JSON.stringify(context, null, 2)}</pre>
            </details>
            {startChat.isError ? (
              <Notice role="alert" tone="danger">
                {errorMessage(startChat.error, t("workbench.discuss.chat_failed"))}
              </Notice>
            ) : null}
            <div className="flex justify-end gap-2 border-t border-border pt-4">
              <Button onClick={() => setOpen(false)} type="button" variant="secondary">
                {t("workbench.discuss.cancel")}
              </Button>
              <Button disabled={startChat.isPending || capturing} type="submit">
                {startChat.isPending ? t("workbench.discuss.starting") : t("workbench.discuss.submit")}
              </Button>
            </div>
          </form>
        </Modal>
      ) : null}
    </>
  )
}
