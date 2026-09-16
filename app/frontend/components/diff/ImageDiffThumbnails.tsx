import { useT } from "../../hooks/useT"
import { jobSourceImageUrl } from "../../api/jobs"
import { MediaPreviewShell } from "../../routes/chat/mediaPreviewShell"
import type { ReviewableDiffFile } from "./ReviewableDiff"

// Renders a before/after thumbnail pair for an image file diff (patch-less,
// `is_image: true`) — the click-to-expand modal is the same one used for
// chat media attachments (MediaPreviewShell), not a bespoke lightbox.
export function ImageDiffThumbnails({
  baseRef,
  file,
  headRef,
  jobId
}: {
  baseRef: string | null | undefined
  file: ReviewableDiffFile
  headRef: string | null | undefined
  jobId: string | number
}) {
  const { t } = useT("common")
  const hasBefore = file.status !== "added"
  const hasAfter = file.status !== "removed"
  const beforeUnavailableLabel = !hasBefore ? t("diff_review.image_no_previous_version") : t("diff_review.image_previous_unavailable")
  const afterUnavailableLabel = !hasAfter ? t("diff_review.image_no_new_version") : t("diff_review.image_new_unavailable")

  return (
    <div className="flex flex-wrap items-start gap-4 border-t border-gray-100 px-4 py-6 dark:border-gray-800">
      {hasBefore && baseRef ? (
        <MediaPreviewShell
          item={{ alt: file.path, src: jobSourceImageUrl(jobId, baseRef, file.path), subtitle: file.path, title: t("diff_review.image_before") }}
          modalLabel={t("diff_review.image_before")}
        />
      ) : (
        <ImageDiffPlaceholder label={beforeUnavailableLabel} title={t("diff_review.image_before")} />
      )}
      {hasAfter && headRef ? (
        <MediaPreviewShell
          item={{ alt: file.path, src: jobSourceImageUrl(jobId, headRef, file.path), subtitle: file.path, title: t("diff_review.image_after") }}
          modalLabel={t("diff_review.image_after")}
        />
      ) : (
        <ImageDiffPlaceholder label={afterUnavailableLabel} title={t("diff_review.image_after")} />
      )}
    </div>
  )
}

function ImageDiffPlaceholder({ label, title }: { label: string; title: string }) {
  return (
    <div className="block w-56 max-w-full overflow-hidden rounded border border-dashed border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
      <span className="flex aspect-video w-full items-center justify-center bg-gray-50 px-3 text-center text-xs font-semibold uppercase text-gray-400 dark:bg-gray-900 dark:text-gray-600">
        {label}
      </span>
      <span className="block truncate px-2 pt-1 text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{title}</span>
    </div>
  )
}
