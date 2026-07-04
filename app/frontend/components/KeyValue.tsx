import type { ReactNode } from "react"

export function KeyValue({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div>
      <div className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="mt-1 text-gray-800 dark:text-gray-200">{children}</div>
    </div>
  )
}
