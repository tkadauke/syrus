import type { ReactNode } from "react"
import { Notice } from "./ui/Notice"

const colors = {
  error: "danger",
  success: "success",
  warning: "warning",
  muted: "neutral"
} as const

export function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" | "warning" }) {
  return <Notice tone={colors[tone]}>{children}</Notice>
}
