export type DiffLineKind = "file" | "meta" | "hunk" | "add" | "delete" | "context" | "no_newline"

export type DiffLine = {
  kind: DiffLineKind
  oldLine: number | null
  newLine: number | null
  marker: string
  code: string
  // Groups "add"/"delete"/"context" lines that came from the same @@ hunk,
  // so a caller can tokenize each hunk's visible lines as one contiguous
  // blob (see UnifiedDiffTable). -1 for lines outside any hunk body
  // ("file"/"meta"/the "hunk" header line itself).
  hunkId: number
  // Only set on "hunk" lines: the parsed `@@ -oldStart,oldLines +newStart,newLines @@` header,
  // used to compute how much hidden context sits above/below/between hunks.
  hunkOldStart?: number
  hunkOldLines?: number
  hunkNewStart?: number
  hunkNewLines?: number
}

export type LineAnnotation = "covered" | "uncovered" | "not_executable"

// Large-diff defaults. Kept as named constants (not scattered magic numbers)
// so call sites can override them via ReviewableDiff props when a different
// default makes sense for their surface.
export const DEFAULT_LARGE_FILE_ROW_THRESHOLD = 300
export const DEFAULT_MAX_VISIBLE_FILES = 100
export const CONTEXT_EXPAND_LINE_INCREMENT = 20

// File-level virtualization defaults (see ReviewableDiff's windowing). Rows
// are estimated, not measured, before a file section first mounts -- these
// are pixel guesses close enough to keep scroll position stable and avoid a
// visible jump once the real height is measured after mount.
export const DEFAULT_FILE_ROW_HEIGHT_PX = 21
export const DEFAULT_FILE_HEADER_HEIGHT_PX = 37
export const DEFAULT_FILE_PLACEHOLDER_HEIGHT_PX = 150
export const DEFAULT_FILE_UNAVAILABLE_HEIGHT_PX = 90
// Overscan is in *files*, not rows: how many extra file sections above/below
// the viewport stay mounted so ordinary scrolling never shows a blank gap
// while a newly-scrolled-to file's real height is still being measured.
export const DEFAULT_FILE_VIRTUALIZATION_OVERSCAN = 6

export function diffCoverageBorderClass(annotation: LineAnnotation | undefined) {
  if (annotation === "covered") return "border-l-2 border-emerald-500"
  if (annotation === "uncovered") return "border-l-2 border-red-500"
  return ""
}

export function splitLines(text: string): string[] {
  const rawLines = text.replace(/\r\n/g, "\n").split("\n")
  if (rawLines.at(-1) === "") rawLines.pop()
  return rawLines
}

// The one non-`+`/`-`/leading-space/`@@`/`diff --git` line unified diffs are
// expected to contain: git (and most patch producers) emit this immediately
// after the last line of a hunk when that line has no trailing newline in
// the file. It carries no line-number/content information of its own, so it
// gets its own kind instead of falling into the generic "meta" bucket that
// `parseUnifiedDiff`'s fallback branch uses for genuinely unexpected input.
export const NO_NEWLINE_MARKER = "\\ No newline at end of file"

// Standard git extended-diff-header lines that legitimately show up outside
// any hunk (alongside "diff --git ", which gets its own "file" kind). These
// are expected structure, not parse failures, so the generic-fallback
// warning in parseUnifiedDiff below must not fire for them.
const RECOGNIZED_META_PREFIXES = [
  "--- ", "+++ ", "index ", "old mode ", "new mode ", "deleted file mode ",
  "new file mode ", "copy from ", "copy to ", "rename from ", "rename to ",
  "similarity index ", "dissimilarity index ", "Binary files "
]

function isRecognizedDiffPreambleLine(rawLine: string): boolean {
  return RECOGNIZED_META_PREFIXES.some((prefix) => rawLine.startsWith(prefix))
}

export function parseUnifiedDiff(diff: string) {
  const rawLines = splitLines(diff)

  const lines: DiffLine[] = []
  let oldLine: number | null = null
  let newLine: number | null = null
  let hunkId = -1

  for (const rawLine of rawLines) {
    const hunk = rawLine.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/)
    if (hunk) {
      const hunkOldStart = Number(hunk[1])
      const hunkOldLines = hunk[2] !== undefined ? Number(hunk[2]) : 1
      const hunkNewStart = Number(hunk[3])
      const hunkNewLines = hunk[4] !== undefined ? Number(hunk[4]) : 1
      oldLine = hunkOldStart
      newLine = hunkNewStart
      hunkId += 1
      lines.push({ kind: "hunk", oldLine: null, newLine: null, marker: "", code: rawLine, hunkId, hunkOldStart, hunkOldLines, hunkNewStart, hunkNewLines })
      continue
    }

    if (rawLine.startsWith("diff --git ")) {
      lines.push(diffLine("file", rawLine))
    } else if (rawLine.startsWith("+") && !rawLine.startsWith("+++")) {
      lines.push(diffLine("add", rawLine.slice(1), null, newLine, "+", hunkId))
      if (newLine !== null) newLine += 1
    } else if (rawLine.startsWith("-") && !rawLine.startsWith("---")) {
      lines.push(diffLine("delete", rawLine.slice(1), oldLine, null, "-", hunkId))
      if (oldLine !== null) oldLine += 1
    } else if (rawLine.startsWith(" ") && oldLine !== null && newLine !== null) {
      lines.push(diffLine("context", rawLine.slice(1), oldLine, newLine, "", hunkId))
      oldLine += 1
      newLine += 1
    } else if (rawLine === NO_NEWLINE_MARKER) {
      lines.push(diffLine("no_newline", rawLine))
    } else {
      // Genuinely unexpected: a line inside the diff that doesn't match any
      // known unified-diff prefix (e.g. a hunk-body line arriving before
      // oldLine/newLine are set because the patch was truncated or
      // reordered, or a line the API forwarded without normalizing). This
      // silently loses the gutter/coverage alignment for that row, so make
      // it visible in dev instead of degrading without a trace.
      if (import.meta.env.DEV && !isRecognizedDiffPreambleLine(rawLine)) {
        console.warn("parseUnifiedDiff: unexpected line inside diff, falling back to \"meta\" classification", rawLine)
      }
      lines.push(diffLine("meta", rawLine))
    }
  }

  return lines
}

export function diffLine(kind: DiffLineKind, code: string, oldLine: number | null = null, newLine: number | null = null, marker = "", hunkId = -1): DiffLine {
  return { kind, oldLine, newLine, marker, code, hunkId }
}

export function diffLineClass(kind: DiffLineKind) {
  switch (kind) {
    case "add": return "bg-green-50 dark:bg-green-950/40"
    case "delete": return "bg-red-50 dark:bg-red-950/40"
    case "hunk": return "bg-info/10 text-info"
    case "file": return "bg-gray-100 font-semibold dark:bg-gray-800 dark:text-gray-100"
    case "meta": case "no_newline": return "bg-gray-50 text-gray-500 dark:bg-gray-900 dark:text-gray-400"
    default: return "bg-white dark:bg-gray-950"
  }
}

export function diffGutterClass(kind: DiffLineKind) {
  const base = "w-12 select-none border-r px-2 py-0.5 text-right text-gray-400"
  switch (kind) {
    case "add": return `${base} border-green-200 bg-green-100 text-green-700 dark:border-green-900 dark:bg-green-950/60 dark:text-green-300`
    case "delete": return `${base} border-red-200 bg-red-100 text-red-700 dark:border-red-900 dark:bg-red-950/60 dark:text-red-300`
    case "hunk": return `${base} border-info/30 bg-info/10 text-info`
    default: return `${base} border-gray-200 bg-gray-50 dark:border-gray-800 dark:bg-gray-900 dark:text-gray-500`
  }
}

export function diffMarkerClass(kind: DiffLineKind) {
  const base = "w-6 select-none px-2 py-0.5 text-center"
  switch (kind) {
    case "add": return `${base} text-green-700`
    case "delete": return `${base} text-red-700`
    case "hunk": return `${base} text-info`
    default: return `${base} text-gray-300`
  }
}

// --- Large-diff row counting -------------------------------------------------

// "Rendered diff row count" per the gating requirement: count parsed rows,
// not raw source bytes, so a file with a tiny patch against a huge source
// file isn't gated, and vice versa.
export function countDiffRows(patch: string | null | undefined): number {
  if (!patch) return 0
  return parseUnifiedDiff(patch).length
}

// --- Word-occurrence highlighting tokenizer ---------------------------------

export type CodeToken = { text: string; highlightable: boolean }

const WORD_TOKEN_PATTERN = /^[A-Za-z_$][A-Za-z0-9_$]*$|^[0-9]+(?:\.[0-9]+)?$/

// Splits a line of code into identifier/number tokens (clickable) plus
// whitespace-run and single-punctuation-character tokens (never clickable),
// so highlighting never triggers on punctuation-only clicks or matches
// inside a run of whitespace.
export function tokenizeCode(code: string): CodeToken[] {
  if (!code) return []
  const parts = code.match(/[A-Za-z_$][A-Za-z0-9_$]*|[0-9]+(?:\.[0-9]+)?|\s+|./gs) || []
  return parts.map((text) => ({ text, highlightable: WORD_TOKEN_PATTERN.test(text) }))
}

// --- Hidden-context expansion math ------------------------------------------

export type HunkMeta = {
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
}

export function hunksFromLines(lines: DiffLine[]): HunkMeta[] {
  const hunks: HunkMeta[] = []
  for (const line of lines) {
    if (line.kind === "hunk" && line.hunkNewStart != null && line.hunkOldStart != null) {
      hunks.push({
        oldStart: line.hunkOldStart,
        oldLines: line.hunkOldLines ?? 0,
        newStart: line.hunkNewStart,
        newLines: line.hunkNewLines ?? 0
      })
    }
  }
  return hunks
}

// A "gap" is a run of hidden, unchanged lines between two hunks (or between
// the start of the file and the first hunk, or the last hunk and EOF).
// `offset` converts a new-file line number in the gap to its old-file line
// number (constant across the gap, since nothing changes inside one).
export type ContextGap = {
  startNew: number
  endNew: number
  offset: number
}

// `totalFileLines` is null when the full file hasn't been fetched yet. The
// trailing gap (after the last hunk) can't be bounded without it, so it's
// treated as unbounded (Infinity) until a fetch resolves the real length —
// this is what lets the UI show the "load more below" control optimistically
// before the backend can prove whether there's really more content there.
export function contextGapsForHunks(hunks: HunkMeta[], totalFileLines: number | null): ContextGap[] {
  const gaps: ContextGap[] = []
  for (let i = 0; i <= hunks.length; i++) {
    const prev = hunks[i - 1]
    const next = hunks[i]
    const startNew = prev ? prev.newStart + prev.newLines : 1
    const offset = prev ? (prev.newStart + prev.newLines) - (prev.oldStart + prev.oldLines) : 0
    const endNew = next ? next.newStart - 1 : (totalFileLines != null ? totalFileLines : Number.POSITIVE_INFINITY)
    gaps.push({ startNew, endNew, offset })
  }
  return gaps
}

export type RevealedGapSegment = { startNew: number; endNew: number }
export type GapRevealState = { fromTop: number; fromBottom: number; segments?: RevealedGapSegment[] }

export type AnnotationVisibilityRange = {
  side: "old" | "new"
  start_line: number
  end_line: number
}

export function gapSize(gap: ContextGap): number {
  return Math.max(0, gap.endNew - gap.startNew + 1)
}

export function remainingInGap(gap: ContextGap, state: GapRevealState | undefined): number {
  const size = gapSize(gap)
  return Math.max(0, size - revealedIntervalsForGap(gap, state).reduce((sum, interval) => sum + interval.endNew - interval.startNew + 1, 0))
}

// Splices revealed context lines (sourced from the fetched full-file
// content) around each hunk. Existing hunk lines are never touched or
// renumbered, so line-comment anchors (keyed by old/new line number) keep
// pointing at the right row after expansion.
export function mergeContextIntoLines(lines: DiffLine[], gaps: ContextGap[], gapStates: Array<GapRevealState | undefined>, fileLines: string[] | null): DiffLine[] {
  if (!fileLines || fileLines.length === 0) return lines

  const resolvedFileLines = fileLines
  const result: DiffLine[] = []

  function appendGap(gap: ContextGap | undefined, state: GapRevealState | undefined, hunkIds: { bottom: number; top: number }) {
    if (!gap) return
    const size = gapSize(gap)
    if (size <= 0 || !state) return
    const intervals = revealedIntervalsForGap(gap, state)

    for (const interval of intervals) {
      const hunkId = interval.endNew === gap.endNew ? hunkIds.bottom : hunkIds.top
      for (let newLine = interval.startNew; newLine <= interval.endNew; newLine++) {
        result.push(contextLineAt(newLine, gap.offset, resolvedFileLines, hunkId))
      }
    }
  }

  let hunkIndex = 0
  for (const line of lines) {
    if (line.kind === "hunk") {
      appendGap(gaps[hunkIndex], gapStates[hunkIndex], { bottom: hunkIndex, top: Math.max(0, hunkIndex - 1) })
      hunkIndex += 1
    }
    result.push(line)
  }
  appendGap(gaps[hunkIndex], gapStates[hunkIndex], { bottom: Math.max(0, hunkIndex - 1), top: Math.max(0, hunkIndex - 1) })
  return result
}

function contextLineAt(newLine: number, offset: number, fileLines: string[], hunkId: number): DiffLine {
  return diffLine("context", fileLines[newLine - 1] ?? "", newLine - offset, newLine, "", hunkId)
}

export function fullyRevealedGapStates(gaps: ContextGap[]): GapRevealState[] {
  return gaps.map((gap) => ({ fromTop: gapSize(gap), fromBottom: 0 }))
}

export function mergeGapRevealStates(
  currentStates: Array<GapRevealState | undefined>,
  requiredStates: Array<GapRevealState | undefined>
): Array<GapRevealState | undefined> {
  const length = Math.max(currentStates.length, requiredStates.length)
  const merged: Array<GapRevealState | undefined> = []

  for (let index = 0; index < length; index++) {
    const current = currentStates[index]
    const required = requiredStates[index]
    if (!current && !required) continue

    const segments = [...(current?.segments ?? []), ...(required?.segments ?? [])]
    merged[index] = {
      fromBottom: Math.max(current?.fromBottom ?? 0, required?.fromBottom ?? 0),
      fromTop: Math.max(current?.fromTop ?? 0, required?.fromTop ?? 0),
      ...(segments.length > 0 ? { segments } : {})
    }
  }

  return merged
}

export function forcedGapStatesForAnnotationRanges(
  gaps: ContextGap[],
  ranges: AnnotationVisibilityRange[],
  contextLineCount: number
): Array<GapRevealState | undefined> {
  const states: Array<GapRevealState | undefined> = []
  const context = Math.max(0, contextLineCount)

  for (const range of ranges) {
    const start = Math.min(range.start_line, range.end_line) - context
    const end = Math.max(range.start_line, range.end_line) + context

    gaps.forEach((gap, index) => {
      const required = requiredRevealForGap(gap, range.side, start, end)
      if (!required) return

      states[index] = mergeGapRevealStates([states[index]], [required])[0]
    })
  }

  return states
}

function requiredRevealForGap(gap: ContextGap, side: "old" | "new", startLine: number, endLine: number): GapRevealState | null {
  const size = gapSize(gap)
  if (size <= 0) return null

  const gapStart = side === "old" ? gap.startNew - gap.offset : gap.startNew
  const gapEnd = side === "old" ? gap.endNew - gap.offset : gap.endNew
  const visibleStart = Math.max(gapStart, startLine)
  const visibleEnd = Math.min(gapEnd, endLine)
  if (visibleStart > visibleEnd) return null

  const visibleStartNew = side === "old" ? visibleStart + gap.offset : visibleStart
  const visibleEndNew = side === "old" ? visibleEnd + gap.offset : visibleEnd
  if (visibleStartNew === gap.startNew) return { fromTop: Math.max(0, visibleEndNew - gap.startNew + 1), fromBottom: 0 }
  if (visibleEndNew === gap.endNew) return { fromTop: 0, fromBottom: Math.max(0, gap.endNew - visibleStartNew + 1) }

  return { fromTop: 0, fromBottom: 0, segments: [{ startNew: visibleStartNew, endNew: visibleEndNew }] }
}

function revealedIntervalsForGap(gap: ContextGap, state: GapRevealState | undefined): RevealedGapSegment[] {
  if (!state) return []

  const size = gapSize(gap)
  if (size <= 0) return []

  const intervals: RevealedGapSegment[] = []
  const fromTop = Math.min(state.fromTop, size)
  if (fromTop > 0) intervals.push({ startNew: gap.startNew, endNew: gap.startNew + fromTop - 1 })

  for (const segment of state.segments ?? []) {
    const startNew = Math.max(gap.startNew, segment.startNew)
    const endNew = Math.min(gap.endNew, segment.endNew)
    if (startNew <= endNew) intervals.push({ startNew, endNew })
  }

  const fromBottom = Math.min(state.fromBottom, size)
  if (fromBottom > 0) intervals.push({ startNew: gap.endNew - fromBottom + 1, endNew: gap.endNew })

  return mergeIntervals(intervals)
}

function mergeIntervals(intervals: RevealedGapSegment[]): RevealedGapSegment[] {
  const sorted = intervals.filter((interval) => interval.startNew <= interval.endNew).sort((a, b) => a.startNew - b.startNew || a.endNew - b.endNew)
  const merged: RevealedGapSegment[] = []

  for (const interval of sorted) {
    const previous = merged.at(-1)
    if (previous && interval.startNew <= previous.endNew + 1) {
      previous.endNew = Math.max(previous.endNew, interval.endNew)
    } else {
      merged.push({ ...interval })
    }
  }

  return merged
}
