const REDACTED = "[redacted]"

const SENSITIVE_KEY_PATTERN =
  /(^|[_-])(access[_-]?token|api[_-]?key|apikey|authorization|auth[_-]?token|bearer|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)([_-]|$)/i
const INLINE_SECRET_KEY_PATTERN =
  "(?:accessToken|access[_-]?token|apiKey|api[_-]?key|apikey|clientSecret|client[_-]?secret|credential|idToken|id[_-]?token|password|refreshToken|refresh[_-]?token|secret|sessionToken|session[_-]?token|token)"
const INLINE_SECRET_ASSIGNMENT_KEY_PATTERN =
  "[A-Za-z0-9_-]*(?:access[_-]?token|api[_-]?key|apikey|auth[_-]?token|client[_-]?secret|credential|github[_-]?token|id[_-]?token|jwt|password|private[_-]?key|refresh[_-]?token|secret|session[_-]?token|token)[A-Za-z0-9_-]*"
const SAFE_SENSITIVE_METADATA_KEY_PATTERN = /(?:^|_)(?:present|active|usable|mode|id|name|type|class|count|error_message|inactive_reason)$/i
const IDENTIFIER_VALUE_KEY_PATTERN = /(?:^|_)(?:key_names?|resource_names?|name)$/i
const SECRET_RESOURCE_METADATA_KEY_PATTERN = /^(?:name|namespace|type|key_count|key_names|created_at)$/i

export function redactToolCardValue(value: unknown, parentKey = ""): unknown {
  if (typeof value === "string") return redactToolCardText(value, !identifierValueKey(parentKey))
  if (Array.isArray(value)) return value.map((item) => redactToolCardValue(item, parentKey))
  if (!isPlainObject(value)) return value

  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, redactToolCardEntry(key, entry)]))
}

export function redactToolCardText(text: string, redactBareSecretIdentifier = true): string {
  const redacted = text
    .replace(/-----BEGIN [^-\r\n]+ PRIVATE KEY-----[\s\S]*?-----END [^-\r\n]+ PRIVATE KEY-----/gi, REDACTED)
    .replace(/(\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@]+:)[^\s/@]+(@)/gi, `$1${REDACTED}$2`)
    .replace(/(\s-u\s+[^\s:]+:)([^\s]+)/g, `$1${REDACTED}`)
    .replace(/\b(Bearer\s+)[A-Za-z0-9._~+/=-]{12,}/gi, `$1${REDACTED}`)
    .replace(new RegExp(`(["'])(${INLINE_SECRET_KEY_PATTERN})\\1(\\s*:\\s*)(["'])[^"']{6,}\\4`, "gi"), `$1$2$1$3$4${REDACTED}$4`)
    .replace(
      new RegExp(
        `(?<![A-Za-z])(${INLINE_SECRET_ASSIGNMENT_KEY_PATTERN})(\\s*[:=]\\s*)("(?:\\\\.|[^"\\\\\\n\\r])*"|'(?:\\\\.|[^'\\\\\\n\\r])*'|[^\\s,;}{]+)`,
        "gi"
      ),
      (_match, key, separator, value) => {
        const quote = value.startsWith('"') || value.startsWith("'") ? value[0] : ""

        return `${key}${separator}${quote}${REDACTED}${quote}`
      }
    )
    .replace(/\b(gh[pousr]_[A-Za-z0-9_]{20,})\b/g, REDACTED)
    .replace(/\b(sk-[A-Za-z0-9_-]{20,})\b/g, REDACTED)

  if (!redactBareSecretIdentifier) return redacted

  return redacted.replace(/\b[A-Za-z0-9._-]*(?:credential|password|secret|token)[A-Za-z0-9._-]{6,}\b(?!\s*[:=])/gi, REDACTED)
}

export function toolCardPayloadSizeLabel(value: string): string {
  const bytes = new TextEncoder().encode(value).length
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function sensitiveKey(key: string) {
  return SENSITIVE_KEY_PATTERN.test(normalizedKey(key))
}

function redactToolCardEntry(key: string, value: unknown) {
  if (!sensitiveKey(key) || safeSensitiveMetadataKey(key)) return redactToolCardValue(value, key)
  if (typeof value !== "string" && !Array.isArray(value) && !isPlainObject(value)) return value
  if (credentialMetadataObject(key, value)) return redactToolCardValue(value, key)
  if (secretResourceMetadataObject(key, value)) return redactSecretResourceMetadata(value)

  return REDACTED
}

function safeSensitiveMetadataKey(key: string) {
  return SAFE_SENSITIVE_METADATA_KEY_PATTERN.test(normalizedKey(key))
}

function identifierValueKey(key: string) {
  return IDENTIFIER_VALUE_KEY_PATTERN.test(normalizedKey(key))
}

function credentialMetadataObject(key: string, value: unknown) {
  return /(?:^|_)credential$/.test(normalizedKey(key)) && isPlainObject(value)
}

function secretResourceMetadataObject(key: string, value: unknown): value is Record<string, unknown> {
  return normalizedKey(key) === "secret" && isPlainObject(value)
}

function redactSecretResourceMetadata(value: Record<string, unknown>) {
  return Object.fromEntries(
    Object.entries(value).map(([key, entry]) => [
      key,
      SECRET_RESOURCE_METADATA_KEY_PATTERN.test(normalizedKey(key)) ? redactToolCardValue(entry, key) : REDACTED
    ])
  )
}

function normalizedKey(key: string) {
  return key.replace(/([a-z0-9])([A-Z])/g, "$1_$2")
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}
