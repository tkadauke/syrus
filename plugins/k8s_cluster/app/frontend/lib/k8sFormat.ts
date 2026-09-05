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
