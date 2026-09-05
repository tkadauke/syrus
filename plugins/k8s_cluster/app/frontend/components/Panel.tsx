import type { ReactNode } from "react"

export function Panel({ children, tone = "neutral" }: { children: ReactNode; tone?: "neutral" | "error" | "success" }) {
  const classes = tone === "error"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
    : tone === "success"
      ? "border-emerald-200 bg-emerald-50 text-emerald-800 dark:border-emerald-900 dark:bg-emerald-950 dark:text-emerald-200"
      : "border-gray-200 bg-white text-gray-700 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-200"
  return <div className={`rounded border px-4 py-3 text-sm ${classes}`}>{children}</div>
}

export function StatusBadge({ children, tone }: { children: ReactNode; tone: "success" | "neutral" | "warning" | "error" }) {
  const classes = tone === "success"
    ? "bg-emerald-50 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"
    : tone === "warning"
      ? "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"
      : tone === "error"
        ? "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300"
        : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${classes}`}>{children}</span>
}
