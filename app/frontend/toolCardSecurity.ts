const REDACTED = "[redacted]"

const SENSITIVE_KEY_PATTERN = /(^|[_-])(access[_-]?token|api[_-]?key|apikey|authorization|auth[_-]?token|bearer|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)([_-]|$)/i
const INLINE_SECRET_KEY_PATTERN = "(?:accessToken|access[_-]?token|apiKey|api[_-]?key|apikey|clientSecret|client[_-]?secret|credential|idToken|id[_-]?token|password|refreshToken|refresh[_-]?token|secret|sessionToken|session[_-]?token|token)"

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
  return text
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi, `$1${REDACTED}`)
    .replace(new RegExp(`(["'])(${INLINE_SECRET_KEY_PATTERN})\\1(\\s*:\\s*)(["'])[^"']{6,}\\4`, "gi"), `$1$2$1$3$4${REDACTED}$4`)
    .replace(new RegExp(`\\b(${INLINE_SECRET_KEY_PATTERN})(\\s*[:=]\\s*)(["']?)[^"'\\s,;}{]{6,}(["']?)`, "gi"), `$1$2$3${REDACTED}$4`)
    .replace(/\b(gh[pousr]_[A-Za-z0-9_]{20,})\b/g, REDACTED)
    .replace(/\b(sk-[A-Za-z0-9_-]{20,})\b/g, REDACTED)
}

export function toolCardPayloadSizeLabel(value: string): string {
  const bytes = new TextEncoder().encode(value).length
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function sensitiveKey(key: string) {
  return SENSITIVE_KEY_PATTERN.test(key.replace(/([a-z0-9])([A-Z])/g, "$1_$2"))
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
