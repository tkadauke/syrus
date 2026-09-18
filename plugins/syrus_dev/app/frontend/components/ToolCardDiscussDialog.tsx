import { type RefObject, useCallback } from "react"
import type { Shape } from "@app/components/ImageAnnotationModal"
import { useT } from "@app/hooks/useT"
import { resolveExampleResultBody } from "@app/pluginToolCards"
import type { ToolOwnerType, ToolPresentationEntry, ToolPresentationExample, ToolSourceType } from "@app/toolPresentationRegistry"
import { CatalogFeedbackDialog } from "../catalog/CatalogFeedbackDialog"
import type { ViewportPresetId } from "../catalog/catalogViewport"
import { rendererTypeFor, type RendererType } from "../toolCardCatalogTypes"

// The Tool Card Catalog's "Discuss this card" feedback flow: capture a
// screenshot of the currently rendered example preview, let the operator
// annotate it by reusing the same ImageAnnotationModal BugReportButton.tsx
// already drives, collect a free-text prompt, then hand the whole bundle
// (screenshot + vector annotation shapes + structured tool/example
// metadata) to a brand new chat -- so the assistant on the other end never
// needs the operator to hand-paste JSON to know what card, example, and
// payload they're looking at.

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

export type ToolCardDiscussButtonProps = {
  deepLink: string
  entry: ToolPresentationEntry
  example: ToolPresentationExample
  previewRef: RefObject<HTMLElement | null>
  viewportPresetId: ViewportPresetId
}

export function ToolCardDiscussButton({ deepLink, entry, example, previewRef, viewportPresetId }: ToolCardDiscussButtonProps) {
  const { t } = useT("syrus_dev")
  const buildMetadata = useCallback(
    (annotations: Shape[]) => buildToolCardFeedbackMetadata(entry, example, viewportPresetId, deepLink, annotations),
    [entry, example, viewportPresetId, deepLink]
  )

  return (
    <CatalogFeedbackDialog
      attachmentName={`${entry.toolName}-tool-card.png`}
      buildMetadata={buildMetadata}
      buildPrompt={buildToolCardFeedbackPrompt}
      copy={{
        trigger: t("tool_cards.discuss.trigger"),
        modalAria: t("tool_cards.discuss.modal_aria", { tool: entry.displayLabel }),
        heading: t("tool_cards.discuss.heading", { tool: entry.displayLabel }),
        close: t("tool_cards.discuss.close"),
        capturing: t("tool_cards.discuss.capturing"),
        captureFailed: t("tool_cards.discuss.capture_failed"),
        screenshotAlt: t("tool_cards.discuss.screenshot_alt", { tool: entry.displayLabel }),
        annotate: t("tool_cards.discuss.annotate"),
        promptLabel: t("tool_cards.discuss.prompt_label"),
        promptPlaceholder: t("tool_cards.discuss.prompt_placeholder"),
        metadataSummary: t("tool_cards.discuss.metadata_summary"),
        chatFailed: t("tool_cards.discuss.chat_failed"),
        cancel: t("tool_cards.discuss.cancel"),
        submit: t("tool_cards.discuss.submit"),
        starting: t("tool_cards.discuss.starting")
      }}
      previewRef={previewRef}
    />
  )
}
