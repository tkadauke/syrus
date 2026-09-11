const REDACTED = "[redacted]"

const SENSITIVE_KEY_PATTERN = /(^|[_-])(api[_-]?key|authorization|auth[_-]?token|bearer|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)([_-]|$)/i
const INLINE_SECRET_PATTERNS: RegExp[] = [
  /\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi,
  /\b(token|access_token|refresh_token|id_token|api_key|apikey|secret|password|credential)(\s*[:=]\s*)(["']?)[^"'\s,;}{]{6,}(["']?)/gi,
  /\b(gh[pousr]_[A-Za-z0-9_]{20,})\b/g,
  /\b(sk-[A-Za-z0-9_-]{20,})\b/g
]

export function redactToolCardValue(value: unknown): unknown {
  if (typeof value === "string") return redactToolCardText(value)
  if (Array.isArray(value)) return value.map((item) => redactToolCardValue(item))
  if (!isPlainObject(value)) return value

  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [
    key,
    sensitiveKey(key) ? REDACTED : redactToolCardValue(entry)
  ]))
}

export function redactToolCardText(text: string): string {
  return INLINE_SECRET_PATTERNS.reduce((redacted, pattern) => (
    redacted.replace(pattern, (...matches: string[]) => {
      if (matches.length >= 5 && matches[2] !== undefined) return `${matches[1]}${matches[2]}${matches[3] || ""}${REDACTED}${matches[4] || ""}`
      if (matches[1]?.startsWith("Bearer ")) return `${matches[1]}${REDACTED}`
      return REDACTED
    })
  ), text)
}

export function toolCardPayloadSizeLabel(value: string): string {
  const bytes = new TextEncoder().encode(value).length
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function sensitiveKey(key: string) {
  return SENSITIVE_KEY_PATTERN.test(key)
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
