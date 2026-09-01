// Small pure class/format helpers extracted from JobDetail.tsx.
//
// Tailwind class strings for the artifact panel, the action-menu buttons (by
// tone), and the pagination links, plus the short-SHA formatter. No component
// or JobDetail-local coupling.
import type { ButtonTone } from "../../lib/buttonClasses"

export function artifactPanelClass() {
  return "mt-3 rounded border border-gray-200 bg-gray-50 max-md:fixed max-md:inset-0 max-md:z-50 max-md:mt-0 max-md:flex max-md:h-[100dvh] max-md:flex-col max-md:rounded-none max-md:border-0 max-md:bg-white dark:border-gray-700 dark:bg-gray-950 max-md:dark:bg-gray-950"
}

export function menuButtonClass(tone: ButtonTone) {
  const tones = {
    primary: "text-brand hover:bg-brand/10 hover:text-brand dark:text-brand-emphasis dark:hover:bg-brand/10 dark:hover:text-brand-emphasis",
    secondary: "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800",
    success: "text-emerald-700 hover:bg-emerald-50 dark:text-emerald-200 dark:hover:bg-emerald-950/40",
    danger: "text-red-700 hover:bg-red-50 dark:text-red-200 dark:hover:bg-red-950/40",
    "danger-outline": "text-red-700 hover:bg-red-50 dark:text-red-200 dark:hover:bg-red-950/40"
  }
  return `block w-full px-4 py-2 text-left text-sm disabled:cursor-not-allowed disabled:opacity-50 ${tones[tone]}`
}

export function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
}

export function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
}

export function shortSha(sha: string | null) {
  return sha ? sha.slice(0, 7) : "unknown"
}

export { withRoutePrefix } from "../../lib/routing"

export function jobSlug(id: number) {
  return `JOB-${id}`
}
export function formatDuration(startedAt: string | null, finishedAt: string | null): string {
  if (!startedAt || !finishedAt) return "-"
  const ms = new Date(finishedAt).getTime() - new Date(startedAt).getTime()
  if (ms < 0) return "-"
  const totalSeconds = Math.floor(ms / 1000)
  if (totalSeconds < 60) return `${totalSeconds}s`
  const hours = Math.floor(totalSeconds / 3600)
  const minutes = Math.floor((totalSeconds % 3600) / 60)
  const seconds = totalSeconds % 60
  if (hours >= 1) return `${hours}h ${minutes}m`
  return `${minutes}m ${seconds}s`
}

export { formatCurrency } from "../../lib/format"

export function plural(count: number, singular: string) {
  if (count !== 1 && singular.endsWith("y")) return `${singular.slice(0, -1)}ies`
  return count === 1 ? singular : `${singular}s`
}
