import type { HTMLAttributes } from "react"
import { classes } from "./ui/classes"

export const attentionBadgeColorClass = "bg-danger text-surface"

export function AttentionBadge({ className, ...props }: HTMLAttributes<HTMLSpanElement>) {
  return <span className={classes(attentionBadgeColorClass, className)} {...props} />
}
