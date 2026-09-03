export type DiffLineKind = "file" | "meta" | "hunk" | "add" | "delete" | "context"
export type DiffLine = {
  kind: DiffLineKind
  oldLine: number | null
  newLine: number | null
  marker: string
  code: string
}

export type LineAnnotation = "covered" | "uncovered" | "not_executable"

export function diffCoverageBorderClass(annotation: LineAnnotation | undefined) {
  if (annotation === "covered") return "border-l-2 border-emerald-500"
  if (annotation === "uncovered") return "border-l-2 border-red-500"
  return ""
}

export function parseUnifiedDiff(diff: string) {
  const rawLines = diff.replace(/\r\n/g, "\n").split("\n")
  if (rawLines.at(-1) === "") rawLines.pop()

  const lines: DiffLine[] = []
  let oldLine: number | null = null
  let newLine: number | null = null

  for (const rawLine of rawLines) {
    const hunk = rawLine.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
    if (hunk) {
      oldLine = Number(hunk[1])
      newLine = Number(hunk[2])
      lines.push(diffLine("hunk", rawLine))
      continue
    }

    if (rawLine.startsWith("diff --git ")) {
      lines.push(diffLine("file", rawLine))
    } else if (rawLine.startsWith("+") && !rawLine.startsWith("+++")) {
      lines.push(diffLine("add", rawLine.slice(1), null, newLine, "+"))
      if (newLine !== null) newLine += 1
    } else if (rawLine.startsWith("-") && !rawLine.startsWith("---")) {
      lines.push(diffLine("delete", rawLine.slice(1), oldLine, null, "-"))
      if (oldLine !== null) oldLine += 1
    } else if (rawLine.startsWith(" ") && oldLine !== null && newLine !== null) {
      lines.push(diffLine("context", rawLine.slice(1), oldLine, newLine))
      oldLine += 1
      newLine += 1
    } else {
      lines.push(diffLine("meta", rawLine))
    }
  }

  return lines
}

export function diffLine(kind: DiffLineKind, code: string, oldLine: number | null = null, newLine: number | null = null, marker = "") {
  return { kind, oldLine, newLine, marker, code }
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
