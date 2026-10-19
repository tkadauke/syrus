export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

// Normalize the result variants emitted by MCP-capable agent providers into
// the payload shape consumed by tool cards.
export function normalizedToolCardParsedResult(parsed: unknown): unknown {
  if (typeof parsed === "string") {
    try {
      return normalizedToolCardParsedResult(JSON.parse(parsed))
    } catch {
      return parsed
    }
  }
  if (!isPlainObject(parsed)) return parsed

  if (parsed.structured_content != null) return normalizedToolCardParsedResult(parsed.structured_content)

  const content = parsed.content
  if (!Array.isArray(content)) return parsed

  const firstContent = content[0]
  if (!isPlainObject(firstContent) || typeof firstContent.text !== "string") return parsed

  try {
    return normalizedToolCardParsedResult(JSON.parse(firstContent.text))
  } catch {
    return parsed
  }
}
