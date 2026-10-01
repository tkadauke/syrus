import type { PluginReviewAnnotationComponentProps } from "@app/pluginReviewAnnotations"

const MARKER_CLASS =
  "inline-flex min-h-4 min-w-4 items-center justify-center rounded-full bg-warning-bg px-1 text-[10px] font-semibold text-warning-text ring-1 ring-inset ring-warning-border"

export default function CognitiveReviewNoteMarker({ item }: PluginReviewAnnotationComponentProps) {
  const title = item.title || ("body" in item ? item.body : null) || undefined

  return (
    <span className={MARKER_CLASS} data-diff-review-annotation-marker="true" title={title}>
      1
    </span>
  )
}
