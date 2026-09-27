// Minimal JSON-to-YAML serializer for the read-only resource detail drawer.
// The describe endpoints return plain parsed JSON (objects, arrays, scalars,
// null), so this only needs that subset -- not a full YAML emitter. Kept
// dependency-free on purpose: `yaml` is only a transitive dependency here,
// and pulling a new direct dependency for a read-only `<pre>` view would be
// disproportionate.
export function toYaml(value: unknown, indent = 0): string {
  const pad = "  ".repeat(indent)

  if (value === null || value === undefined) return "null"
  if (typeof value === "boolean" || typeof value === "number") return String(value)
  if (typeof value === "string") return quoteString(value)
  if (Array.isArray(value)) {
    if (value.length === 0) return "[]"
    return value.map((item) => `${pad}- ${toYamlInline(item, indent)}`).join("\n")
  }
  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>)
    if (entries.length === 0) return "{}"
    return entries.map(([key, item]) => `${pad}${quoteKey(key)}:${toYamlBlock(item, indent)}`).join("\n")
  }
  return String(value)
}

// A nested value on the line after `key:` -- scalars stay on the same line,
// collections start on the next line one level deeper.
function toYamlBlock(value: unknown, indent: number): string {
  if (value !== null && typeof value === "object") return `\n${toYaml(value, indent + 1)}`
  return ` ${toYaml(value, indent)}`
}

// A nested value after `- ` -- scalars stay on the same line, collections
// start on the next line one level deeper than the item.
function toYamlInline(value: unknown, indent: number): string {
  if (value !== null && typeof value === "object") return `\n${toYaml(value, indent + 1)}`
  return toYaml(value, indent)
}

function quoteKey(key: string) {
  if (/^[A-Za-z0-9_-]+$/.test(key)) return key
  return forceQuote(key)
}

function forceQuote(value: string) {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t")}"`
}

function quoteString(value: string) {
  if (value !== "" && !needsQuoting(value)) return value
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t")}"`
}

function needsQuoting(value: string) {
  if (/^\s|\s$/.test(value)) return true
  if (/[\n\r\t]/.test(value)) return true
  if (/[:#\[\]{},&*!|>'"%@`?]/.test(value)) return true
  if (/^\d/.test(value) || /^(true|false|null|yes|no|on|off)$/i.test(value)) return true
  return false
}
