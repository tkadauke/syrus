import { useEffect, useState, type ReactNode } from "react"
import { useT } from "../../hooks/useT"
import { jobSourceImageUrl } from "../../api/jobs"
import { Markdown } from "../../lib/Markdown"
import type { ReviewableDiffFile } from "./ReviewableDiff"

export type RenderedFileKind = "image" | "markdown" | "svg"
export type RenderedFileContents = { before: string | null; after: string | null }

export function renderedFileKind(file: ReviewableDiffFile): RenderedFileKind | null {
  const extension = file.path.toLowerCase().match(/\.[^.\/]+$/)?.[0]
  if (extension === ".svg") return "svg"
  if ([".md", ".markdown", ".mdown"].includes(extension || "")) return "markdown"
  return file.is_image ? "image" : null
}

export function InlineRenderedFileComparison({
  baseRef,
  file,
  headRef,
  jobId,
  kind = renderedFileKind(file),
  loadContents
}: {
  baseRef: string | null | undefined
  file: ReviewableDiffFile
  headRef: string | null | undefined
  jobId: string | number
  kind?: RenderedFileKind | null
  loadContents?: () => Promise<RenderedFileContents>
}) {
  const { t } = useT("common")
  const [expanded, setExpanded] = useState<"before" | "after" | null>(null)
  const [contents, setContents] = useState<RenderedFileContents | null>(null)
  const [loadState, setLoadState] = useState<"idle" | "loading" | "error">("idle")
  const [loadedSides, setLoadedSides] = useState<Set<"before" | "after">>(() => new Set())
  const [failedSides, setFailedSides] = useState<Set<"before" | "after">>(() => new Set())
  const hasBefore = file.status !== "added"
  const hasAfter = file.status !== "removed"

  useEffect(() => {
    if (kind !== "markdown" || !loadContents) return
    let active = true
    setLoadState("loading")
    loadContents()
      .then((value) => {
        if (!active) return
        setContents(value)
        setLoadState("idle")
      })
      .catch(() => active && setLoadState("error"))
    return () => {
      active = false
    }
    // The loader is intentionally excluded: route render callbacks are often
    // created inline, while the file identity is the actual cache boundary.
  }, [kind, file.path])

  const sides = (["before", "after"] as const).filter((side) => (side === "before" ? hasBefore : hasAfter))
  return (
    <div
      className={`grid gap-4 border-t border-gray-100 px-4 py-4 dark:border-gray-800 ${expanded || sides.length === 1 ? "grid-cols-1" : "md:grid-cols-2"}`}
      data-testid="rendered-file-comparison"
    >
      {sides
        .filter((side) => !expanded || expanded === side)
        .map((side) => {
          const ref = side === "before" ? baseRef : headRef
          const title = t(side === "before" ? "diff_review.image_before" : "diff_review.image_after")
          return (
            <section className="min-w-0 overflow-hidden rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-950" key={side}>
              <header className="flex items-center justify-between border-b border-gray-100 px-3 py-2 text-xs font-semibold uppercase text-gray-500 dark:border-gray-800 dark:text-gray-400">
                {title}
                {sides.length > 1 ? (
                  <button
                    className="rounded px-2 py-1 hover:bg-gray-100 dark:hover:bg-gray-800"
                    onClick={() => setExpanded(expanded ? null : side)}
                    type="button"
                  >
                    {t(expanded ? "diff_review.restore_comparison" : "diff_review.expand_preview")}
                  </button>
                ) : null}
              </header>
              <div className="min-h-40 overflow-auto p-4">
                {kind === "markdown" ? (
                  renderMarkdownSide(contents?.[side] ?? null, loadState, t)
                ) : failedSides.has(side) ? (
                  <PreviewMessage>{t("diff_review.preview_failed")}</PreviewMessage>
                ) : ref ? (
                  <>
                    {!loadedSides.has(side) ? <p className="pb-2 text-center text-xs text-text-muted">{t("loading")}</p> : null}
                    <img
                      alt={`${title}: ${file.path}`}
                      className="mx-auto max-h-[70vh] max-w-full object-contain"
                      onError={() => setFailedSides((current) => new Set(current).add(side))}
                      onLoad={() => setLoadedSides((current) => new Set(current).add(side))}
                      src={jobSourceImageUrl(jobId, ref, file.path)}
                    />
                  </>
                ) : (
                  <PreviewMessage>{t(side === "before" ? "diff_review.image_previous_unavailable" : "diff_review.image_new_unavailable")}</PreviewMessage>
                )}
              </div>
            </section>
          )
        })}
    </div>
  )
}

function renderMarkdownSide(content: string | null, state: "idle" | "loading" | "error", t: (key: string) => string): ReactNode {
  if (state === "loading") return <PreviewMessage>{t("loading")}</PreviewMessage>
  if (state === "error" || content == null) return <PreviewMessage>{t("diff_review.preview_unavailable")}</PreviewMessage>
  return <Markdown className="max-w-none" linkifySlugs={false} text={content} />
}

function PreviewMessage({ children }: { children: ReactNode }) {
  return <div className="flex min-h-32 items-center justify-center text-center text-sm text-text-muted">{children}</div>
}

export const ImageDiffThumbnails = InlineRenderedFileComparison
