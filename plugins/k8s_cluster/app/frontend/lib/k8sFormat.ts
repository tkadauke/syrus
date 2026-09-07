// Shared display formatting for the cluster viewer tabs. Kept intentionally
// simple - callers only need a compact, human-readable string, not a
// full duration/units library.
export function formatAge(createdAt: string | null | undefined, now: Date = new Date()): string {
  if (!createdAt) return "-"

  const created = new Date(createdAt)
  if (Number.isNaN(created.getTime())) return "-"

  const seconds = Math.max(0, Math.floor((now.getTime() - created.getTime()) / 1000))
  if (seconds < 60) return `${seconds}s`

  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`

  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`

  const days = Math.floor(hours / 24)
  if (days < 365) return `${days}d`

  return `${Math.floor(days / 365)}y`
}

export function formatMillicores(millicores: number): string {
  if (millicores >= 1000) return `${(millicores / 1000).toFixed(2)} vCPU`
  return `${millicores}m`
}

export function formatBytes(bytes: number): string {
  if (!bytes) return "0 B"
  const units = [ "B", "KB", "MB", "GB", "TB", "PB" ]
  const exponent = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1)
  const value = bytes / 1024 ** exponent
  return `${value.toFixed(exponent === 0 ? 0 : 1)} ${units[exponent]}`
}

const BINARY_MEMORY_SUFFIXES: Record<string, number> = {
  Ki: 1024,
  Mi: 1024 ** 2,
  Gi: 1024 ** 3,
  Ti: 1024 ** 4,
  Pi: 1024 ** 5,
  Ei: 1024 ** 6
}

const DECIMAL_MEMORY_SUFFIXES: Record<string, number> = {
  K: 1000,
  M: 1000 ** 2,
  G: 1000 ** 3,
  T: 1000 ** 4,
  P: 1000 ** 5,
  E: 1000 ** 6
}

export function kubernetesCpuMillicores(value: string | null | undefined): number | null {
  if (!value) return null
  if (value.endsWith("n")) return Math.round(Number(value.slice(0, -1)) / 1_000_000)
  if (value.endsWith("u")) return Math.round(Number(value.slice(0, -1)) / 1_000)
  if (value.endsWith("m")) return Number.parseInt(value.slice(0, -1), 10)

  const cores = Number(value)
  return Number.isFinite(cores) ? Math.round(cores * 1000) : null
}

export function kubernetesMemoryBytes(value: string | null | undefined): number | null {
  if (!value) return null

  const suffix = Object.keys(BINARY_MEMORY_SUFFIXES).find((candidate) => value.endsWith(candidate)) ??
    Object.keys(DECIMAL_MEMORY_SUFFIXES).find((candidate) => value.endsWith(candidate))
  if (!suffix) {
    const bytes = Number(value)
    return Number.isFinite(bytes) ? bytes : null
  }

  const numeric = Number(value.slice(0, -suffix.length))
  if (!Number.isFinite(numeric)) return null

  return Math.round(numeric * (BINARY_MEMORY_SUFFIXES[suffix] ?? DECIMAL_MEMORY_SUFFIXES[suffix]))
}

export function formatKubernetesCpu(value: string | null | undefined): string {
  const millicores = kubernetesCpuMillicores(value)
  if (millicores === null) return value || "-"
  if (millicores < 1000) return `${millicores}m`

  const cores = millicores / 1000
  return `${Number.isInteger(cores) ? cores.toFixed(0) : cores.toFixed(2).replace(/0$/, "")} vCPU`
}

export function formatKubernetesMemory(value: string | null | undefined): string {
  const bytes = kubernetesMemoryBytes(value)
  return bytes === null ? value || "-" : formatBytes(bytes)
}
