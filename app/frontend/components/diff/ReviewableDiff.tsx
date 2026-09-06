import { Fragment, type ReactNode, useEffect, useMemo, useState } from "react"
import type { ThemedToken } from "@shikijs/core"
import { Button } from "../Button"
import { renderCodeLine } from "../CodeBlock"
import { detectHighlighterLanguage, tokenizeLines, type HighlighterLanguageId } from "../../lib/highlighter"
import { diffCoverageBorderClass, diffGutterClass, diffLineClass, diffMarkerClass, parseUnifiedDiff, type DiffLine, type DiffLineKind, type LineAnnotation } from "./diffRendering"

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
  changedFilesPopup?: boolean
  comments?: Record<string, Record<string, DiffReviewThread[]>> | null
  composingBody?: string
  composingError?: Error | null
  composingPending?: boolean
  composingSelection?: DiffLineSelection | null
  editingThreadBody?: string
  editingThreadId?: number | null
  emptyState?: ReactNode
  fileCommentCounts?: Record<string, number>
  files?: ReviewableDiffFile[]
  mode?: "single-file" | "continuous"
  onCancelComposing?: () => void
  onCancelEditThread?: () => void
  onChangeComposingBody?: (body: string) => void
  onChangeEditingThreadBody?: (body: string) => void
  onCommentLine?: (selection: DiffLineSelection) => void
  onDeleteThread?: (thread: DiffReviewThread) => void
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onSelectFile?: (path: string) => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  scroll?: "bounded" | "natural"
  selectedPath?: string | null
  showFileHeaders?: boolean | "continuous"
  unavailableState?: ReactNode
}

export type ReviewableUnifiedDiffProps = Omit<ReviewableDiffProps, "files"> & {
  diff: string
}

export function ReviewableDiff({
  annotations,
  changedFilesPopup = false,
  comments,
  composingBody,
  composingError,
  composingPending,
  composingSelection,
  editingThreadBody,
  editingThreadId,
  emptyState = null,
  fileCommentCounts,
  files = [],
  mode = "single-file",
  onCancelComposing,
  onCancelEditThread,
  onChangeComposingBody,
  onChangeEditingThreadBody,
  onCommentLine,
  onDeleteThread,
  onSaveComposing,
  onSaveEditThread,
  onSelectFile,
  onStartEditThread,
  scroll = "bounded",
  selectedPath,
  showFileHeaders = "continuous",
  unavailableState = "Diff not available"
}: ReviewableDiffProps) {
  const [filesPopupOpen, setFilesPopupOpen] = useState(false)
  const renderFiles = filesForMode(files, mode, selectedPath)

  if (renderFiles.length === 0) return <>{emptyState}</>

  const containerClass = scroll === "natural"
    ? "bg-white font-mono text-xs dark:bg-gray-950"
    : "max-h-[32rem] overflow-y-auto bg-white font-mono text-xs max-md:min-h-0 max-md:flex-1 max-md:max-h-none dark:bg-gray-950"

  function selectFileFromPopup(path: string) {
    onSelectFile?.(path)
    setFilesPopupOpen(false)
    document.querySelector(`[data-diff-file="${CSS.escape(path)}"]`)?.scrollIntoView({ block: "start" })
  }

  return (
    <div className="relative" data-testid="agent-diff-viewer">
      <div className={containerClass}>
        {renderFiles.map((file, index) => (
          <section className={index > 0 ? "border-t border-gray-200 dark:border-gray-800" : ""} data-diff-file={file.path} key={file.path}>
            {showFileHeaders === true || (showFileHeaders === "continuous" && mode === "continuous") ? (
              <DiffFileHeader
                file={file}
                onSelectFile={onSelectFile}
                onToggleFilesPopup={changedFilesPopup ? () => setFilesPopupOpen((open) => !open) : undefined}
                selected={selectedPath === file.path}
                showFilesPopupTrigger={changedFilesPopup}
              />
            ) : null}
            {file.patch !== null ? (
              <UnifiedDiffTable
                annotations={annotationsForFile(annotations, file.path)}
                comments={comments?.[file.path]}
                composingBody={composingBody}
                composingError={composingError}
                composingPending={composingPending}
                composingSelection={composingSelection?.file.path === file.path ? composingSelection : undefined}
                editingThreadBody={editingThreadBody}
                editingThreadId={editingThreadId}
                file={file}
                onCancelComposing={onCancelComposing}
                onCancelEditThread={onCancelEditThread}
                onChangeComposingBody={onChangeComposingBody}
                onChangeEditingThreadBody={onChangeEditingThreadBody}
                onCommentLine={onCommentLine}
                onDeleteThread={onDeleteThread}
                onSaveComposing={onSaveComposing}
                onSaveEditThread={onSaveEditThread}
                onStartEditThread={onStartEditThread}
              />
            ) : (
              <div className="px-4 py-8 text-center font-sans text-sm text-gray-400 dark:text-gray-500">{unavailableState}</div>
            )}
          </section>
        ))}
      </div>
      {changedFilesPopup && filesPopupOpen ? (
        <ChangedFilesPopup
          commentCounts={fileCommentCounts}
          files={files}
          onClose={() => setFilesPopupOpen(false)}
          onSelectFile={selectFileFromPopup}
          selectedPath={selectedPath}
        />
      ) : null}
    </div>
  )
}

export function AgentDiff({ annotations, diff, ...props }: ReviewableUnifiedDiffProps & { annotations?: Record<string, LineAnnotation> }) {
  return <ReviewableDiff annotations={annotations} files={filesFromUnifiedDiff(diff)} mode="continuous" {...props} />
}

function ChangedFilesPopup({
  commentCounts,
  files,
  onClose,
  onSelectFile,
  selectedPath
}: {
  commentCounts?: Record<string, number>
  files: ReviewableDiffFile[]
  onClose: () => void
  onSelectFile: (path: string) => void
  selectedPath?: string | null
}) {
  return (
    <div className="fixed inset-0 z-30" onClick={onClose}>
      <div
        className="absolute right-4 top-14 max-h-[70vh] w-80 overflow-auto rounded border border-gray-200 bg-white font-mono text-xs shadow-lg dark:border-gray-700 dark:bg-gray-900"
        onClick={(event) => event.stopPropagation()}
        role="dialog"
      >
        <p className="border-b border-gray-100 px-3 py-2 font-sans text-xs font-semibold uppercase tracking-wide text-gray-500 dark:border-gray-800 dark:text-gray-400">Changed files</p>
        {files.map((file) => (
          <button
            className={`flex w-full items-center gap-2 px-3 py-2 text-left hover:bg-brand/10 ${selectedPath === file.path ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 dark:text-gray-300"}`}
            key={file.path}
            onClick={() => onSelectFile(file.path)}
            title={`${file.path} (+${file.additions ?? 0} -${file.deletions ?? 0})`}
            type="button"
          >
            <span className="min-w-0 flex-1 truncate">{file.path}</span>
            {typeof file.additions === "number" ? <span className="text-emerald-600 dark:text-emerald-400">+{file.additions}</span> : null}
            {typeof file.deletions === "number" ? <span className="text-red-600 dark:text-red-400">-{file.deletions}</span> : null}
            {commentCounts?.[file.path] ? <span className="rounded bg-amber-100 px-1.5 py-0.5 text-2xs font-semibold text-amber-800 dark:bg-amber-950 dark:text-amber-200">{commentCounts[file.path]}</span> : null}
          </button>
        ))}
      </div>
    </div>
  )
}

// Tokenizes each hunk's visible lines as one contiguous blob (grouped by
// `hunkId`, see diffRendering.ts) rather than the full source file, since
// only the diff payload -- not full before/after file content -- reaches
// this component. This is a deliberate, documented limitation: a
// multi-line construct (a heredoc, a block comment, a template literal)
// whose opening line falls outside the visible hunk can highlight
// incorrectly at the hunk boundary, because Shiki has no grammar state
// from before the hunk to continue from.
function useHighlightedDiffLines(lines: DiffLine[], lang: HighlighterLanguageId | null): (ThemedToken[] | undefined)[] {
  const [tokensByIndex, setTokensByIndex] = useState<(ThemedToken[] | undefined)[]>([])

  useEffect(() => {
    setTokensByIndex([])
    if (!lang) return

    const hunkLineIndexes = new Map<number, number[]>()
    lines.forEach((line, index) => {
      if (line.hunkId < 0 || !isDiffCodeLine(line.kind)) return
      const indexes = hunkLineIndexes.get(line.hunkId) ?? []
      indexes.push(index)
      hunkLineIndexes.set(line.hunkId, indexes)
    })

    let cancelled = false
    Promise.all(
      Array.from(hunkLineIndexes.values()).map(async (indexes) => {
        const code = indexes.map((index) => lines[index].code).join("\n")
        const tokens = await tokenizeLines(code, lang)
        return indexes.map((lineIndex, tokenIndex) => [lineIndex, tokens[tokenIndex]] as const)
      })
    ).then((groups) => {
      if (cancelled) return
      const result: (ThemedToken[] | undefined)[] = []
      for (const group of groups) {
        for (const [lineIndex, tokens] of group) result[lineIndex] = tokens
      }
      setTokensByIndex(result)
    })

    return () => {
      cancelled = true
    }
  }, [lines, lang])

  return tokensByIndex
}

function isDiffCodeLine(kind: DiffLine["kind"]) {
  return kind === "add" || kind === "delete" || kind === "context"
}

export function UnifiedDiffTable({
  annotations,
  comments,
  composingBody,
  composingError,
  composingPending,
  composingSelection,
  editingThreadBody,
  editingThreadId,
  file,
  onCancelComposing,
  onCancelEditThread,
  onChangeComposingBody,
  onChangeEditingThreadBody,
  onCommentLine,
  onDeleteThread,
  onSaveComposing,
  onSaveEditThread,
  onStartEditThread,
  testId
}: {
  annotations?: Record<string, LineAnnotation>
  comments?: Record<string, DiffReviewThread[]>
  composingBody?: string
  composingError?: Error | null
  composingPending?: boolean
  composingSelection?: DiffLineSelection | null
  editingThreadBody?: string
  editingThreadId?: number | null
  file: ReviewableDiffFile
  onCancelComposing?: () => void
  onCancelEditThread?: () => void
  onChangeComposingBody?: (body: string) => void
  onChangeEditingThreadBody?: (body: string) => void
  onCommentLine?: (selection: DiffLineSelection) => void
  onDeleteThread?: (thread: DiffReviewThread) => void
  onSaveComposing?: () => void
  onSaveEditThread?: () => void
  onStartEditThread?: (thread: DiffReviewThread) => void
  testId?: string
}) {
  const lines = useMemo(() => parseUnifiedDiff(file.patch || ""), [file.patch])
  const lang = detectHighlighterLanguage(file.path)
  const tokensByLine = useHighlightedDiffLines(lines, lang)
  const composingKey = composingSelection ? anchorKeyForLine(composingSelection.line, composingSelection.side) : null

  return (
    <div className="overflow-x-auto" data-testid={testId ? `${testId}-scroll` : "diff-file-scroll"}>
      <table className="min-w-full border-separate border-spacing-0 font-mono text-xs" data-testid={testId}>
        <tbody>
          {lines.map((line, index) => {
            const annotation = line.newLine != null ? annotations?.[String(line.newLine)] : undefined
            const commentSide = line.newLine != null ? "new" : line.oldLine != null ? "old" : null
            const canComment = Boolean(onCommentLine && commentSide)
            const threads = commentSide ? comments?.[anchorKeyForLine(line, commentSide)] || [] : []
            const isComposingHere = Boolean(commentSide && composingKey && composingKey === anchorKeyForLine(line, commentSide))
            return (
              <Fragment key={`${index}-${line.kind}-${line.oldLine || ""}-${line.newLine || ""}`}>
              <tr
                className={`group ${diffLineClass(line.kind)}`}
                data-coverage={annotation}
                data-diff-kind={line.kind}
              >
                <td className={`relative ${diffGutterClass(line.kind)}`}>
                  {commentSide === "old" && canComment ? (
                    <GutterCommentButton file={file} line={line} onCommentLine={onCommentLine} side="old" />
                  ) : null}
                  {line.oldLine ?? ""}
                </td>
                <td className={`relative ${diffGutterClass(line.kind)}`}>
                  {commentSide === "new" && canComment ? (
                    <GutterCommentButton file={file} line={line} onCommentLine={onCommentLine} side="new" />
                  ) : null}
                  {line.newLine ?? ""}
                </td>
                <td className={diffMarkerClass(line.kind)}>{line.marker}</td>
                <td className={`min-w-[40rem] whitespace-pre px-3 py-0.5 text-gray-900 dark:text-gray-200 ${diffCoverageBorderClass(annotation)}`}>{renderCodeLine(tokensByLine[index], line.code || " ")}</td>
                <td className="w-4 select-none px-1 text-center">
                  {annotation === "covered" ? <span className="text-emerald-600 dark:text-emerald-400">✓</span>
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
                            <div className="flex flex-wrap items-center gap-2">
                              {thread.author ? <span>{thread.author}</span> : null}
                              <span>{thread.state}</span>
                              {thread.workflowState ? <span>{thread.workflowState}</span> : null}
                            </div>
                            {thread.state === "draft" && onStartEditThread && editingThreadId !== thread.id ? (
                              <button
                                className="normal-case tracking-normal text-amber-700 underline hover:text-amber-900 dark:text-amber-300 dark:hover:text-amber-100"
                                onClick={() => onStartEditThread(thread)}
                                type="button"
                              >
                                Edit
                              </button>
                            ) : null}
                            {thread.state === "draft" && onDeleteThread && editingThreadId !== thread.id ? (
                              <button
                                className="normal-case tracking-normal text-red-700 underline hover:text-red-900 dark:text-red-300 dark:hover:text-red-100"
                                onClick={() => onDeleteThread(thread)}
                                type="button"
                              >
                                Delete
                              </button>
                            ) : null}
                          </div>
                          {editingThreadId === thread.id ? (
                            <div className="space-y-2">
                              <textarea
                                aria-label={`Edit comment ${thread.id}`}
                                className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                                onChange={(event) => onChangeEditingThreadBody?.(event.target.value)}
                                value={editingThreadBody ?? ""}
                              />
                              <div className="flex gap-2">
                                <Button disabled={!editingThreadBody?.trim()} onClick={onSaveEditThread} size="sm">Save</Button>
                                <Button onClick={onCancelEditThread} size="sm" variant="secondary">Cancel</Button>
                              </div>
                            </div>
                          ) : (
                            <p className="whitespace-pre-wrap break-words text-sm normal-case tracking-normal text-gray-800 dark:text-gray-200">{thread.body}</p>
                          )}
                        </div>
                      ))}
                    </div>
                  </td>
                </tr>
              ) : null}
              {isComposingHere ? (
                <tr className="bg-brand/5 font-sans" data-testid="diff-review-composer">
                  <td className="border-r border-brand/20" colSpan={2} />
                  <td className="text-brand">*</td>
                  <td className="px-3 py-2" colSpan={2}>
                    <div className="space-y-2">
                      <textarea
                        aria-label="Comment"
                        autoFocus
                        className="min-h-20 w-full rounded border border-gray-300 bg-white px-2 py-1 text-sm normal-case tracking-normal text-gray-900 shadow-sm focus:border-brand focus:outline-none focus:ring-2 focus:ring-brand/20 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
                        onChange={(event) => onChangeComposingBody?.(event.target.value)}
                        value={composingBody ?? ""}
                      />
                      <div className="flex gap-2">
                        <Button disabled={!composingBody?.trim() || composingPending} onClick={onSaveComposing} size="sm">Create comment</Button>
                        <Button onClick={onCancelComposing} size="sm" variant="secondary">Cancel</Button>
                      </div>
                      {composingError ? <p className="text-xs text-red-700 dark:text-red-300">Unable to create diff comment.</p> : null}
                    </div>
                  </td>
                </tr>
              ) : null}
              </Fragment>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

export function DiffHunkSnippet({ highlightLine, hunk }: { highlightLine?: string | null; hunk: string }) {
  const lines = hunk.replace(/\r\n/g, "\n").split("\n")
  return (
    <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-800">
      {lines.map((line, index) => (
        <div
          className={`whitespace-pre px-2 py-0.5 font-mono text-2xs ${diffLineClass(hunkLineKind(line))} ${highlightLine != null && line === highlightLine ? "ring-1 ring-inset ring-brand" : ""}`}
          key={index}
        >
          {line || " "}
        </div>
      ))}
    </div>
  )
}

function hunkLineKind(line: string): DiffLineKind {
  if (line.startsWith("@@")) return "hunk"
  if (line.startsWith("+") && !line.startsWith("+++")) return "add"
  if (line.startsWith("-") && !line.startsWith("---")) return "delete"
  return "context"
}

function GutterCommentButton({
  file,
  line,
  onCommentLine,
  side
}: {
  file: ReviewableDiffFile
  line: DiffLine
  onCommentLine?: (selection: DiffLineSelection) => void
  side: "old" | "new"
}) {
  return (
    <button
      aria-label={`Comment on ${file.path}:${side}:${line.newLine ?? line.oldLine}`}
      className="absolute left-0.5 top-1/2 flex h-4 w-4 -translate-y-1/2 items-center justify-center rounded-full bg-brand text-2xs leading-none text-on-brand opacity-0 transition-opacity hover:opacity-100 group-hover:opacity-100"
      onClick={() => onCommentLine?.({ file, line, side })}
      type="button"
    >
      +
    </button>
  )
}

function anchorKeyForLine(line: DiffLine, side: "old" | "new") {
  if (side === "old") return `left:${line.oldLine ?? ""}:${line.newLine ?? ""}`
  return `right:${line.oldLine ?? ""}:${line.newLine ?? ""}`
}

function DiffFileHeader({
  file,
  onSelectFile,
  onToggleFilesPopup,
  selected,
  showFilesPopupTrigger
}: {
  file: ReviewableDiffFile
  onSelectFile?: (path: string) => void
  onToggleFilesPopup?: () => void
  selected: boolean
  showFilesPopupTrigger?: boolean
}) {
  const content = (
    <>
      <span className="min-w-0 flex-1 truncate">{file.path}</span>
      {typeof file.additions === "number" ? <span>+{file.additions}</span> : null}
      {typeof file.deletions === "number" ? <span>-{file.deletions}</span> : null}
    </>
  )
  const className = `sticky top-0 z-10 flex w-full items-center gap-3 border-b border-gray-100 bg-gray-50 px-4 py-2 text-left font-mono text-xs text-gray-600 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400 ${selected ? "text-brand dark:text-brand-emphasis" : ""}`

  return (
    <div className={className} title={file.path}>
      {onSelectFile ? (
        <button className="flex min-w-0 flex-1 items-center gap-3 text-left" onClick={() => onSelectFile(file.path)} type="button">
          {content}
        </button>
      ) : (
        <div className="flex min-w-0 flex-1 items-center gap-3">{content}</div>
      )}
      {showFilesPopupTrigger ? (
        <button
          aria-label="Browse changed files"
          className="shrink-0 rounded border border-gray-300 px-2 py-0.5 font-sans text-2xs font-medium text-gray-600 hover:bg-white dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
          onClick={onToggleFilesPopup}
          type="button"
        >
          Files
        </button>
      ) : null}
    </div>
  )
}

function filesForMode(files: ReviewableDiffFile[], mode: "single-file" | "continuous", selectedPath: string | null | undefined) {
  if (mode === "continuous") return files
  if (!selectedPath) return files.slice(0, 1)
  const selected = files.find((file) => file.path === selectedPath)
  return selected ? [selected] : []
}

export function filesFromUnifiedDiff(diff: string): ReviewableDiffFile[] {
  const normalized = diff.replace(/\r\n/g, "\n").trimEnd()
  if (!normalized) return []

  const rawFiles = normalized.split(/\n(?=diff --git )/)
  const files = rawFiles.map((patch, index) => {
    const path = pathFromPatch(patch) || (rawFiles.length === 1 ? "diff" : `diff-${index + 1}`)
    return {
      path,
      patch,
      additions: patch.split("\n").filter((line) => line.startsWith("+") && !line.startsWith("+++")).length,
      deletions: patch.split("\n").filter((line) => line.startsWith("-") && !line.startsWith("---")).length,
      status: statusFromPatch(patch)
    }
  })

  return files.length > 0 ? files : [{ path: "diff", patch: normalized }]
}

function pathFromPatch(patch: string) {
  const header = patch.match(/^diff --git a\/(.+?) b\/(.+)$/m)
  if (header) return header[2]

  const newPath = patch.match(/^\+\+\+ b\/(.+)$/m)
  if (newPath) return newPath[1]

  const oldPath = patch.match(/^--- a\/(.+)$/m)
  return oldPath?.[1] || null
}

function statusFromPatch(patch: string) {
  if (/^new file mode /m.test(patch)) return "added"
  if (/^deleted file mode /m.test(patch)) return "removed"
  if (/^rename from /m.test(patch) || /^rename to /m.test(patch)) return "renamed"
  return "modified"
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
