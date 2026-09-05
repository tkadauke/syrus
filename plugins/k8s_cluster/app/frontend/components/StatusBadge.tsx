import type { ReactNode } from "react"

// Small inline status badge, distinct from the core StatusPill/TonePill
// (rounded-full ring pills for Job/Run/Workflow states): this is a compact
// rounded-rect badge for Kubernetes resource fields (pod phase, PVC bound
// status, node readiness) with its own success/neutral/warning/error tone
// vocabulary.
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
