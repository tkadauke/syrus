export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

export function parseJsonText(value: string): unknown {
  const trimmed = value.trim()
  if (!trimmed) return null

  let current: unknown = trimmed
  for (let index = 0; index < 3; index += 1) {
    if (typeof current !== "string") return current
    const candidate = current.trim()
    if (!candidate.startsWith("{") && !candidate.startsWith("[") && !candidate.startsWith('"')) return index === 0 ? null : current

    try {
      current = JSON.parse(candidate)
    } catch {
      return index === 0 ? null : current
    }
  }

  return current
}

export function normalizedToolCardParsedResult(parsed: unknown): unknown {
  if (!isPlainObject(parsed)) return parsed

  if (parsed.structured_content != null) {
    const content = parsed.content
    const preservesBinaryContent = Array.isArray(content) && content.some((item) => isPlainObject(item) && item.type !== "text")
    if (!preservesBinaryContent) return parsed.structured_content

    if (!isPlainObject(parsed.structured_content)) return { structured_content: parsed.structured_content, content }

    const structuredBlocks = Array.isArray(parsed.structured_content.content) ? parsed.structured_content.content : []
    return { ...parsed.structured_content, content: [...content, ...structuredBlocks] }
  }

  const content = parsed.content
  if (!Array.isArray(content)) return parsed

  const firstContent = content[0]
  if (!isPlainObject(firstContent) || typeof firstContent.text !== "string") return parsed

  const inner = parseJsonText(firstContent.text)
  return inner == null ? parsed : inner
}
