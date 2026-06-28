import type { ReactNode } from "react"

export type SyntaxLanguage = "ruby" | "javascript" | "typescript" | "json" | "yaml" | "shell" | "css" | "html"

const RUBY_KEYWORDS = new Set([
  "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
  "for", "if", "in", "module", "next", "nil", "not", "or", "private", "protected", "public", "redo", "rescue", "retry",
  "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"
])

const JAVASCRIPT_KEYWORDS = new Set([
  "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "export",
  "extends", "false", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new",
  "null", "return", "switch", "throw", "true", "try", "type", "undefined", "while"
])

export function inferToolResultLanguage(detail: string, tool: string): SyntaxLanguage | null {
  if (tool !== "Read") return null

  const path = firstPathToken(detail)
  if (/\.(rb|rake)\b/.test(path) || /(^|\/)(Gemfile|Rakefile|config\.ru)$/.test(path)) return "ruby"
  if (/\.(ts|tsx)\b/.test(path)) return "typescript"
  if (/\.(js|jsx)\b/.test(path)) return "javascript"
  if (/\.json\b/.test(path)) return "json"
  if (/\.(ya?ml)\b/.test(path)) return "yaml"
  if (/\.(sh|bash|zsh)\b/.test(path) || /(^|\/)(bin|script)\//.test(path)) return "shell"
  if (/\.css\b/.test(path)) return "css"
  if (/\.(html|erb)\b/.test(path)) return "html"

  return null
}

function firstPathToken(value: string) {
  return value.split(/[\s,]+/, 1)[0] || ""
}

export function highlightCode(code: string, language: SyntaxLanguage): ReactNode[] {
  const highlighted: ReactNode[] = []
  const lines = code.split("\n")

  lines.forEach((line, lineIndex) => {
    highlighted.push(...highlightLine(line, language, `line-${lineIndex}`))
    if (lineIndex < lines.length - 1) highlighted.push("\n")
  })

  return highlighted
}

function highlightLine(line: string, language: SyntaxLanguage, keyPrefix: string): ReactNode[] {
  const match = line.match(/^(\s*\d+\s+)(.*)$/)
  const prefix = match?.[1] || ""
  const source = match?.[2] || line
  const nodes: ReactNode[] = []

  if (prefix) nodes.push(<span className="text-gray-400 dark:text-gray-500" key={`${keyPrefix}-number`}>{prefix}</span>)

  nodes.push(...highlightSourceLine(source, language, keyPrefix))
  return nodes
}

function highlightSourceLine(line: string, language: SyntaxLanguage, keyPrefix: string): ReactNode[] {
  if (language === "ruby" || language === "shell" || language === "yaml") {
    return highlightLexedLine(line, {
      keyPrefix,
      commentMarkers: [ "#" ],
      keywords: language === "ruby" ? RUBY_KEYWORDS : new Set<string>()
    })
  }

  if (language === "javascript" || language === "typescript" || language === "json" || language === "css") {
    return highlightLexedLine(line, {
      keyPrefix,
      commentMarkers: language === "json" ? [] : [ "//" ],
      keywords: language === "javascript" || language === "typescript" ? JAVASCRIPT_KEYWORDS : new Set<string>()
    })
  }

  if (language === "html") return highlightHtmlLine(line, keyPrefix)

  return [ line ]
}

function highlightLexedLine(line: string, options: { keyPrefix: string; commentMarkers: string[]; keywords: Set<string> }) {
  const nodes: ReactNode[] = []
  let index = 0
  let part = 0

  function push(text: string, className?: string) {
    if (!text) return
    nodes.push(className ? <span className={className} key={`${options.keyPrefix}-${part++}`}>{text}</span> : text)
  }

  while (index < line.length) {
    const commentMarker = options.commentMarkers.find((marker) => line.startsWith(marker, index))
    if (commentMarker) {
      push(line.slice(index), "text-gray-400 italic dark:text-gray-500")
      break
    }

    const char = line[index]
    if (char === "\"" || char === "'" || char === "`") {
      const end = stringEndIndex(line, index, char)
      push(line.slice(index, end), "text-emerald-700 dark:text-emerald-300")
      index = end
      continue
    }

    const number = line.slice(index).match(/^\b\d+(?:\.\d+)?\b/)
    if (number) {
      push(number[0], "text-amber-700 dark:text-amber-300")
      index += number[0].length
      continue
    }

    const variable = line.slice(index).match(/^[@$][A-Za-z_]\w*/)
    if (variable) {
      push(variable[0], "text-rose-700 dark:text-rose-300")
      index += variable[0].length
      continue
    }

    const symbol = line.slice(index).match(/^:[A-Za-z_]\w*[!?=]?/)
    if (symbol) {
      push(symbol[0], "text-violet-700 dark:text-violet-300")
      index += symbol[0].length
      continue
    }

    const word = line.slice(index).match(/^[A-Za-z_]\w*[!?=]?/)
    if (word) {
      const value = word[0]
      if (options.keywords.has(value)) {
        push(value, "font-semibold text-blue-700 dark:text-blue-300")
      } else if (/^[A-Z]/.test(value)) {
        push(value, "text-cyan-700 dark:text-cyan-300")
      } else {
        push(value)
      }
      index += value.length
      continue
    }

    push(char)
    index += 1
  }

  return nodes
}

function highlightHtmlLine(line: string, keyPrefix: string) {
  const nodes: ReactNode[] = []
  let part = 0

  line.split(/(<\/?[A-Za-z][^>]*>)/g).forEach((segment) => {
    if (!segment) return
    nodes.push(segment.startsWith("<") ? <span className="text-blue-700 dark:text-blue-300" key={`${keyPrefix}-${part++}`}>{segment}</span> : segment)
  })

  return nodes
}

function stringEndIndex(line: string, start: number, quote: string) {
  let index = start + 1
  while (index < line.length) {
    if (line[index] === "\\" && index + 1 < line.length) {
      index += 2
      continue
    }
    if (line[index] === quote) return index + 1
    index += 1
  }

  return line.length
}
