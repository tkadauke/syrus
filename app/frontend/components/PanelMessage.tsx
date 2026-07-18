import type { ReactNode } from "react"

type PanelTone = "success" | "error" | "warning" | "info" | "muted"

export function PanelMessage({ tone, children, className, role }: {
  tone: PanelTone
  children: ReactNode
  className?: string
  role?: string
}) {
  return (
    <div className={`banner-${tone} p-3 text-sm${className ? ` ${className}` : ""}`} role={role}>
      {children}
    </div>
  )
}
