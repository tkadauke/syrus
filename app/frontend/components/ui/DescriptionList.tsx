import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"

export type DescriptionListDensity = "default" | "compact"

export interface DescriptionListRootProps extends HTMLAttributes<HTMLDListElement> {
  density?: DescriptionListDensity
}

export interface DescriptionListItemProps extends HTMLAttributes<HTMLDivElement> {
  children?: ReactNode
  descriptionClassName?: string
  label: ReactNode
  termClassName?: string
}

const ROOT_DENSITY_CLASSES: Record<DescriptionListDensity, string> = {
  default: "gap-x-4 gap-y-3",
  compact: "gap-x-3 gap-y-1.5"
}

function Root({ className = "", density = "default", ...props }: DescriptionListRootProps) {
  return <dl className={classes("grid grid-cols-1 text-sm sm:grid-cols-[max-content_1fr]", ROOT_DENSITY_CLASSES[density], className)} {...props} />
}

function Item({ children, className = "", descriptionClassName = "", label, termClassName = "", ...props }: DescriptionListItemProps) {
  return (
    <div className={classes("grid grid-cols-1 gap-x-4 gap-y-1 sm:contents", className)} {...props}>
      <dt className={classes("text-xs font-medium uppercase tracking-wide text-text-muted", termClassName)}>{label}</dt>
      <dd className={classes("min-w-0 text-sm text-text-primary", descriptionClassName)}>{children}</dd>
    </div>
  )
}

export const DescriptionList = {
  Root,
  Item
}
