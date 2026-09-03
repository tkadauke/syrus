import { Fragment, type ReactNode } from "react"
import { diffCoverageBorderClass, diffGutterClass, diffLineClass, diffMarkerClass, parseUnifiedDiff, type DiffLine, type LineAnnotation } from "./diffRendering"

export type ReviewableDiffFile = {
  path: string
  patch: string | null
  status?: string
  additions?: number
  deletions?: number
}

export type DiffLineSelection = {
  file: ReviewableDiffFile
  line: DiffLine
  side: "old" | "new"
}

export type DiffReviewThread = {
  id: number
  body: string
  state: string
  author?: string | null
  workflowState?: string | null
}

export type ReviewableDiffProps = {
  annotations?: Record<string, Record<string, LineAnnotation>> | Record<string, LineAnnotation> | null
  comments?: Record<string, Record<string, DiffReviewThread[]>> | null
  emptyState?: ReactNode
  files?: ReviewableDiffFile[]
  mode?: "single-file" | "continuous"
  onCommentLine?: (selection: DiffLineSelection) => void
  onSelectFile?: (path: string) => void
  selectedPath?: string | null
  showFileHeaders?: boolean | "continuous"
  unavailableState?: ReactNode
}

export function ReviewableDiff({
  annotations,
  comments,
  emptyState = null,
  files = [],
  mode = "single-file",
  onCommentLine,
  onSelectFile,
  selectedPath,
  showFileHeaders = "continuous",
  unavailableState = "Diff not available"
}: ReviewableDiffProps) {
  const renderFiles = filesForMode(files, mode, selectedPath)

  if (renderFiles.length === 0) return <>{emptyState}</>

  return (
    <div className="max-h-[32rem] overflow-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950" data-testid="agent-diff-viewer">
      {renderFiles.map((file, index) => (
        <section className={index > 0 ? "border-t border-gray-200 dark:border-gray-800" : ""} data-diff-file={file.path} key={file.path}>
          {showFileHeaders === true || (showFileHeaders === "continuous" && mode === "continuous") ? <DiffFileHeader file={file} onSelectFile={onSelectFile} selected={selectedPath === file.path} /> : null}
          {file.patch !== null ? (
            <UnifiedDiffTable
              annotations={annotationsForFile(annotations, file.path)}
              comments={comments?.[file.path]}
              file={file}
              onCommentLine={onCommentLine}
            />
          ) : (
            <div className="px-4 py-8 text-center font-sans text-sm text-gray-400 dark:text-gray-500">{unavailableState}</div>
          )}
        </section>
      ))}
    </div>
  )
}

export function AgentDiff({ annotations, diff }: { diff: string; annotations?: Record<string, LineAnnotation> }) {
  return <ReviewableDiff annotations={annotations} files={[{ path: "diff", patch: diff }]} mode="single-file" />
}

export function UnifiedDiffTable({
  annotations,
  comments,
  file,
  onCommentLine,
  testId
}: {
  annotations?: Record<string, LineAnnotation>
  comments?: Record<string, DiffReviewThread[]>
  file: ReviewableDiffFile
  onCommentLine?: (selection: DiffLineSelection) => void
  testId?: string
}) {
  const lines = parseUnifiedDiff(file.patch || "")

  return (
    <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid={testId}>
      <tbody>
        {lines.map((line, index) => {
          const annotation = line.newLine != null ? annotations?.[String(line.newLine)] : undefined
          const commentSide = line.newLine != null ? "new" : line.oldLine != null ? "old" : null
          const canComment = Boolean(onCommentLine && commentSide)
          const threads = commentSide ? comments?.[anchorKeyForLine(line, commentSide)] || [] : []
          return (
            <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
            <tr
              className={diffLineClass(line.kind)}
              data-coverage={annotation}
              data-diff-kind={line.kind}
            >
              <td className={diffGutterClass(line.kind)}>{line.oldLine ?? ""}</td>
              <td className={diffGutterClass(line.kind)}>{line.newLine ?? ""}</td>
              <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
              <td className={`min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200 ${diffCoverageBorderClass(annotation)}`}>{line.code || " "}</td>
              <td className="w-4 select-none px-1 text-center">
                {canComment ? (
                  <button
                    aria-label={`Comment on ${file.path}:${commentSide}:${line.newLine ?? line.oldLine}`}
                    className="text-gray-300 hover:text-brand dark:text-gray-600 dark:hover:text-brand-emphasis"
                    onClick={() => {
                      if (commentSide) onCommentLine?.({ file, line, side: commentSide })
                    }}
                    type="button"
                  >
                    +
                  </button>
                ) : annotation === "covered" ? <span className="text-emerald-600 dark:text-emerald-400">✓</span>
                  : annotation === "uncovered" ? <span className="text-red-600 dark:text-red-400">✗</span>
                  : null}
              </td>
            </tr>
            {threads.length > 0 ? (
              <tr className="bg-amber-50/70 font-sans dark:bg-amber-950/30" data-testid="diff-review-thread">
                <td className="border-r border-amber-200 dark:border-amber-900" colSpan={2} />
                <td className="text-amber-700 dark:text-amber-300">*</td>
                <td className="px-3 py-2 text-xs text-amber-950 dark:text-amber-100" colSpan={2}>
                  <div className="space-y-2">
                    {threads.map((thread) => (
                      <div className="rounded border border-amber-200 bg-white px-3 py-2 dark:border-amber-900 dark:bg-gray-950" key={thread.id}>
                        <div className="mb-1 flex flex-wrap items-center gap-2 text-2xs font-medium uppercase tracking-wide text-amber-700 dark:text-amber-300">
                          {thread.author ? <span>{thread.author}</span> : null}
                          <span>{thread.state}</span>
                          {thread.workflowState ? <span>{thread.workflowState}</span> : null}
                        </div>
                        <p className="whitespace-pre-wrap break-words text-sm normal-case tracking-normal text-gray-800 dark:text-gray-200">{thread.body}</p>
                      </div>
                    ))}
                  </div>
                </td>
              </tr>
            ) : null}
            </Fragment>
          )
        })}
      </tbody>
    </table>
  )
}

function anchorKeyForLine(line: DiffLine, side: "old" | "new") {
  if (side === "old") return `left:${line.oldLine ?? ""}:${line.newLine ?? ""}`
  return `right:${line.oldLine ?? ""}:${line.newLine ?? ""}`
}

function DiffFileHeader({
  file,
  onSelectFile,
  selected
}: {
  file: ReviewableDiffFile
  onSelectFile?: (path: string) => void
  selected: boolean
}) {
  const content = (
    <>
      <span className="min-w-0 flex-1 truncate">{file.path}</span>
      {typeof file.additions === "number" ? <span>+{file.additions}</span> : null}
      {typeof file.deletions === "number" ? <span>-{file.deletions}</span> : null}
    </>
  )
  const className = `sticky top-0 z-10 flex w-full items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 text-left font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400 ${selected ? "text-brand dark:text-brand-emphasis" : ""}`

  if (onSelectFile) {
    return (
      <button className={className} onClick={() => onSelectFile(file.path)} title={file.path} type="button">
        {content}
      </button>
    )
  }

  return <div className={className} title={file.path}>{content}</div>
}

function filesForMode(files: ReviewableDiffFile[], mode: "single-file" | "continuous", selectedPath: string | null | undefined) {
  if (mode === "continuous") return files
  if (!selectedPath) return files.slice(0, 1)
  const selected = files.find((file) => file.path === selectedPath)
  return selected ? [selected] : []
}

function annotationsForFile(
  annotations: ReviewableDiffProps["annotations"],
  path: string
): Record<string, LineAnnotation> | undefined {
  if (!annotations) return undefined
  if (isLineAnnotations(annotations)) return annotations
  return annotations[path]
}

function isLineAnnotations(annotations: NonNullable<ReviewableDiffProps["annotations"]>): annotations is Record<string, LineAnnotation> {
  return Object.values(annotations).every((value) => typeof value === "string")
}
