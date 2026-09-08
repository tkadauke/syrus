export type DiffLineKind = "file" | "meta" | "hunk" | "add" | "delete" | "context"
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
    } else {
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
    case "meta": return "bg-gray-50 text-gray-500 dark:bg-gray-900 dark:text-gray-400"
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

export type GapRevealState = { fromTop: number; fromBottom: number }

export function gapSize(gap: ContextGap): number {
  return Math.max(0, gap.endNew - gap.startNew + 1)
}

export function remainingInGap(gap: ContextGap, state: GapRevealState | undefined): number {
  const size = gapSize(gap)
  const revealed = (state?.fromTop ?? 0) + (state?.fromBottom ?? 0)
  return Math.max(0, size - revealed)
}

// Splices revealed context lines (sourced from the fetched full-file
// content) around each hunk. Existing hunk lines are never touched or
// renumbered, so line-comment anchors (keyed by old/new line number) keep
// pointing at the right row after expansion.
export function mergeContextIntoLines(lines: DiffLine[], gaps: ContextGap[], gapStates: Array<GapRevealState | undefined>, fileLines: string[] | null): DiffLine[] {
  if (!fileLines || fileLines.length === 0) return lines

  const resolvedFileLines = fileLines
  const result: DiffLine[] = []

  function appendGap(gap: ContextGap | undefined, state: GapRevealState | undefined) {
    if (!gap) return
    const size = gapSize(gap)
    if (size <= 0 || !state) return
    const fromTop = Math.min(state.fromTop, size)
    const fromBottom = Math.min(state.fromBottom, size - fromTop)

    for (let newLine = gap.startNew; newLine < gap.startNew + fromTop; newLine++) {
      result.push(contextLineAt(newLine, gap.offset, resolvedFileLines))
    }
    const bottomStart = Math.max(gap.startNew + fromTop, gap.endNew - fromBottom + 1)
    for (let newLine = bottomStart; newLine <= gap.endNew; newLine++) {
      result.push(contextLineAt(newLine, gap.offset, resolvedFileLines))
    }
  }

  let hunkIndex = -1
  appendGap(gaps[0], gapStates[0])
  for (const line of lines) {
    result.push(line)
    if (line.kind === "hunk") {
      hunkIndex += 1
      appendGap(gaps[hunkIndex + 1], gapStates[hunkIndex + 1])
    }
  }
  return result
}

function contextLineAt(newLine: number, offset: number, fileLines: string[]): DiffLine {
  return diffLine("context", fileLines[newLine - 1] ?? "", newLine - offset, newLine)
}

export function fullyRevealedGapStates(gaps: ContextGap[]): GapRevealState[] {
  return gaps.map((gap) => ({ fromTop: gapSize(gap), fromBottom: 0 }))
}
