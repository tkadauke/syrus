type AnsiStyle = {
  bold: boolean
  dim: boolean
  italic: boolean
  underline: boolean
  fg: string | null
  bg: string | null
  color: string | null
  backgroundColor: string | null
}

type AnsiSegment = {
  text: string
  style: AnsiStyle
}

const CSI_PATTERN = /\u001b\[([0-9;?]*)([@-~])/g

const foregroundClasses: Record<string, string> = {
  "30": "text-gray-950 dark:text-gray-100",
  "31": "text-red-700 dark:text-red-300",
  "32": "text-emerald-700 dark:text-emerald-300",
  "33": "text-amber-700 dark:text-amber-300",
  "34": "text-blue-700 dark:text-blue-300",
  "35": "text-fuchsia-700 dark:text-fuchsia-300",
  "36": "text-cyan-700 dark:text-cyan-300",
  "37": "text-gray-600 dark:text-gray-200",
  "90": "text-gray-500 dark:text-gray-400",
  "91": "text-red-600 dark:text-red-300",
  "92": "text-emerald-600 dark:text-emerald-300",
  "93": "text-amber-600 dark:text-amber-300",
  "94": "text-blue-600 dark:text-blue-300",
  "95": "text-fuchsia-600 dark:text-fuchsia-300",
  "96": "text-cyan-600 dark:text-cyan-300",
  "97": "text-gray-900 dark:text-white"
}

const backgroundClasses: Record<string, string> = {
  "40": "bg-gray-950 dark:bg-gray-100",
  "41": "bg-red-100 dark:bg-red-950/60",
  "42": "bg-emerald-100 dark:bg-emerald-950/60",
  "43": "bg-amber-100 dark:bg-amber-950/60",
  "44": "bg-blue-100 dark:bg-blue-950/60",
  "45": "bg-fuchsia-100 dark:bg-fuchsia-950/60",
  "46": "bg-cyan-100 dark:bg-cyan-950/60",
  "47": "bg-gray-100 dark:bg-gray-800",
  "100": "bg-gray-200 dark:bg-gray-700",
  "101": "bg-red-200 dark:bg-red-900/70",
  "102": "bg-emerald-200 dark:bg-emerald-900/70",
  "103": "bg-amber-200 dark:bg-amber-900/70",
  "104": "bg-blue-200 dark:bg-blue-900/70",
  "105": "bg-fuchsia-200 dark:bg-fuchsia-900/70",
  "106": "bg-cyan-200 dark:bg-cyan-900/70",
  "107": "bg-gray-200 dark:bg-gray-600"
}

const ansi256Colors = [
  "#000000", "#800000", "#008000", "#808000", "#000080", "#800080", "#008080", "#c0c0c0",
  "#808080", "#ff0000", "#00ff00", "#ffff00", "#0000ff", "#ff00ff", "#00ffff", "#ffffff"
]

export function AnsiText({ text }: { text: string }) {
  return (
    <>
      {parseAnsiText(text).map((segment, index) => (
        <span className={ansiStyleClass(segment.style)} key={index} style={ansiInlineStyle(segment.style)}>
          {segment.text}
        </span>
      ))}
    </>
  )
}

export function parseAnsiText(text: string) {
  const segments: AnsiSegment[] = []
  let style = defaultAnsiStyle()
  let lastIndex = 0

  for (const match of text.matchAll(CSI_PATTERN)) {
    const index = match.index ?? 0
    appendAnsiSegment(segments, text.slice(lastIndex, index), style)
    lastIndex = index + match[0].length

    if (match[2] === "m") {
      style = applySgrCodes(style, parseSgrCodes(match[1]))
    }
  }

  appendAnsiSegment(segments, text.slice(lastIndex), style)
  return segments.length > 0 ? segments : [{ text: "", style: defaultAnsiStyle() }]
}

function appendAnsiSegment(segments: AnsiSegment[], text: string, style: AnsiStyle) {
  const cleaned = stripAnsiControls(text)
  if (cleaned.length === 0) return

  segments.push({ text: cleaned, style: { ...style } })
}

function applySgrCodes(style: AnsiStyle, codes: number[]) {
  let next = { ...style }

  for (let index = 0; index < codes.length; index += 1) {
    const code = codes[index]

    if (code === 0) next = defaultAnsiStyle()
    else if (code === 1) next.bold = true
    else if (code === 2) next.dim = true
    else if (code === 3) next.italic = true
    else if (code === 4) next.underline = true
    else if (code === 22) next = { ...next, bold: false, dim: false }
    else if (code === 23) next.italic = false
    else if (code === 24) next.underline = false
    else if (code === 39) next = { ...next, fg: null, color: null }
    else if (code === 49) next = { ...next, bg: null, backgroundColor: null }
    else if (foregroundClasses[String(code)]) next = { ...next, fg: String(code), color: null }
    else if (backgroundClasses[String(code)]) next = { ...next, bg: String(code), backgroundColor: null }
    else if ((code === 38 || code === 48) && codes[index + 1] === 5) {
      const color = ansi256Color(codes[index + 2])
      if (color) next = applyInlineColor(next, code, color)
      index += 2
    } else if ((code === 38 || code === 48) && codes[index + 1] === 2) {
      const color = rgbColor(codes[index + 2], codes[index + 3], codes[index + 4])
      if (color) next = applyInlineColor(next, code, color)
      index += 4
    }
  }

  return next
}

function parseSgrCodes(rawCodes: string) {
  if (rawCodes.trim() === "") return [0]

  const codes = rawCodes.split(";").map((code) => {
    const parsed = Number(code)
    return Number.isFinite(parsed) ? parsed : 0
  })

  return codes.length > 0 ? codes : [0]
}

function applyInlineColor(style: AnsiStyle, code: number, color: string) {
  if (code === 38) return { ...style, fg: null, color }
  return { ...style, bg: null, backgroundColor: color }
}

function ansi256Color(code: number | undefined) {
  if (code == null || code < 0 || code > 255) return null
  if (ansi256Colors[code]) return ansi256Colors[code]

  if (code >= 16 && code <= 231) {
    const color = code - 16
    const red = Math.floor(color / 36)
    const green = Math.floor((color % 36) / 6)
    const blue = color % 6
    return rgbColor(cubeColor(red), cubeColor(green), cubeColor(blue))
  }

  const gray = 8 + (code - 232) * 10
  return rgbColor(gray, gray, gray)
}

function cubeColor(value: number) {
  return value === 0 ? 0 : 55 + value * 40
}

function rgbColor(red: number | undefined, green: number | undefined, blue: number | undefined) {
  if (!validRgbValue(red) || !validRgbValue(green) || !validRgbValue(blue)) return null
  return `rgb(${red}, ${green}, ${blue})`
}

function validRgbValue(value: number | undefined): value is number {
  return value != null && Number.isInteger(value) && value >= 0 && value <= 255
}

function ansiStyleClass(style: AnsiStyle) {
  return [
    style.bold ? "font-semibold" : null,
    style.dim ? "opacity-70" : null,
    style.italic ? "italic" : null,
    style.underline ? "underline" : null,
    style.fg ? foregroundClasses[style.fg] : null,
    style.bg ? backgroundClasses[style.bg] : null
  ].filter(Boolean).join(" ")
}

function ansiInlineStyle(style: AnsiStyle) {
  if (!style.color && !style.backgroundColor) return undefined
  return { color: style.color || undefined, backgroundColor: style.backgroundColor || undefined }
}

function stripAnsiControls(text: string) {
  return text
    .replace(/\u001b\][^\u0007]*(?:\u0007|\u001b\\)/g, "")
    .replace(/\u001b[@-_][0-?]*[ -/]*[@-~]/g, "")
}

function defaultAnsiStyle(): AnsiStyle {
  return {
    bold: false,
    dim: false,
    italic: false,
    underline: false,
    fg: null,
    bg: null,
    color: null,
    backgroundColor: null
  }
}
