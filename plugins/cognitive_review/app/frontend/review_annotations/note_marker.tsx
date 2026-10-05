import type { PluginReviewAnnotationComponentProps } from "@app/pluginReviewAnnotations"

const MARKER_CLASS =
  "inline-flex min-h-4 min-w-4 items-center justify-center rounded-full bg-warning-bg px-1 text-[10px] font-semibold text-warning-text ring-1 ring-inset ring-warning-border"
const HANDLED_MARKER_CLASS =
  "inline-flex min-h-4 min-w-4 items-center justify-center rounded-full bg-success-bg px-1 text-[10px] font-semibold text-success-text ring-1 ring-inset ring-success-border"

export default function CognitiveReviewNoteMarker({ item }: PluginReviewAnnotationComponentProps) {
  const title = item.title || ("body" in item ? item.body : null) || undefined
  const tone = "tone" in item ? item.tone : undefined
  const handled = tone === "success" || (item.props as { handled?: boolean } | undefined)?.handled === true

  return (
    <span className={handled ? HANDLED_MARKER_CLASS : MARKER_CLASS} data-diff-review-annotation-marker="true" title={title}>
      1
    </span>
  )
}
