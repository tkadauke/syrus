export type WorkerCapabilityEntry = {
  dimension: string
  value: string
}

export function workerCapabilityEntries(capabilities: unknown): WorkerCapabilityEntry[] {
  if (!capabilities || typeof capabilities !== "object" || Array.isArray(capabilities)) return []

  return Object.entries(capabilities).flatMap(([dimension, values]) => {
    if (!Array.isArray(values)) return []

    return values.flatMap((value) => {
      const text = typeof value === "string" ? value.trim() : ""
      return text ? [{ dimension, value: text }] : []
    })
  })
}

export function workerCapabilitiesText(capabilities: unknown) {
  return workerCapabilityEntries(capabilities).map((entry) => `${entry.dimension}:${entry.value}`).join(", ")
}
