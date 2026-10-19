import { CodeSurface, Pill } from "../../components/ui"
import { diffLineClass, diffMarkerClass, parseUnifiedDiff } from "../../components/diff/diffRendering"

// Shared raw-diff summary/preview rendering for the get_job_diff, read_pr,
// and read_run_transcript tool cards (the Tier 1 tool-card work). Lives outside
// `tool_cards/` for the same reason as jobsTableCard.tsx / toolCardUi.tsx.
export type DiffStats = { fileCount: number; additions: number; deletions: number }

// Git quotes unusual paths with C-style escapes and encodes non-ASCII bytes as
// octal. Decode the header tokens as bytes so multi-byte UTF-8 paths survive.
function decodeGitPath(token: string): string {
  if (!token.startsWith('"') || !token.endsWith('"')) return token

  const bytes: number[] = []
  const value = token.slice(1, -1)
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index]
    if (character !== "\\") {
      bytes.push(...new TextEncoder().encode(character))
      continue
    }

    const escaped = value[index + 1]
    const octal = value.slice(index + 1).match(/^[0-7]{1,3}/)?.[0]
    if (octal) {
      bytes.push(Number.parseInt(octal, 8))
      index += octal.length
    } else if (escaped) {
      const escapes: Record<string, number> = { a: 7, b: 8, t: 9, n: 10, v: 11, f: 12, r: 13 }
      bytes.push(escapes[escaped] ?? escaped.charCodeAt(0))
      index += 1
    }
  }
  return new TextDecoder().decode(Uint8Array.from(bytes))
}

function gitHeaderTokens(header: string): string[] {
  const tokens: string[] = []
  for (let index = 0; index < header.length;) {
    while (header[index] === " ") index += 1
    if (index >= header.length) break
    const start = index
    if (header[index] === '"') {
      index += 1
      while (index < header.length) {
        if (header[index] === "\\") index += 2
        else if (header[index++] === '"') break
      }
    } else {
      while (index < header.length && header[index] !== " ") index += 1
    }
    tokens.push(header.slice(start, index))
  }
  return tokens
}

export function changedFilePaths(diff: string): string[] {
  const paths = new Set<string>()
  for (const line of diff.split("\n")) {
    if (!line.startsWith("diff --git ")) continue
    const tokens = gitHeaderTokens(line.slice("diff --git ".length))
    if (tokens.length !== 2) continue
    const destination = decodeGitPath(tokens[1]).replace(/^b\//, "")
    if (destination && destination !== "/dev/null") paths.add(destination)
  }
  return [...paths]
}

export function diffStats(diff: string): DiffStats {
  const lines = parseUnifiedDiff(diff)
  return {
    fileCount: lines.filter((line) => line.kind === "file").length,
    additions: lines.filter((line) => line.kind === "add").length,
    deletions: lines.filter((line) => line.kind === "delete").length
  }
}

export function DiffStatBadges({ stats }: { stats: DiffStats }) {
  return (
    <div className="flex flex-wrap items-center gap-2 font-mono text-2xs">
      {stats.fileCount > 0 ? (
        <Pill tone="neutral">
          {stats.fileCount} file{stats.fileCount === 1 ? "" : "s"}
        </Pill>
      ) : null}
      <Pill tone="success">+{stats.additions}</Pill>
      <Pill tone="danger">-{stats.deletions}</Pill>
    </div>
  )
}

const PREVIEW_LINE_LIMIT = 300

export function RawDiffPreview({ diff }: { diff: string }) {
  const allLines = parseUnifiedDiff(diff)
  const lines = allLines.slice(0, PREVIEW_LINE_LIMIT)
  if (lines.length === 0) return null

  return (
    <div className="space-y-1">
      {allLines.length > PREVIEW_LINE_LIMIT ? (
        <div className="text-2xs text-text-muted">
          Showing first {PREVIEW_LINE_LIMIT} of {allLines.length} lines
        </div>
      ) : null}
      <CodeSurface code={diff} copyLabel="Copy diff" maxHeightClassName="max-h-72" mode="multiline">
        {lines.map((line, index) => (
          <span className={`flex ${diffLineClass(line.kind)}`} key={index}>
            <span className={diffMarkerClass(line.kind)}>{line.marker}</span>
            <span className="min-w-0 flex-1 whitespace-pre-wrap break-words px-2 py-0.5">{line.code || " "}</span>
          </span>
        ))}
      </CodeSurface>
    </div>
  )
}
