import type { HTMLAttributes } from "react"
import { classes } from "./classes"
import { surfaceClasses } from "./Surface"
import type { SurfacePadding, SurfaceProps, SurfaceVariant } from "./Surface"
import { Text } from "./Text"
import type { TextProps } from "./Text"

export type SectionTone = "default" | "subtle" | "danger" | "warning" | "success"

export interface SectionRootProps extends Omit<SurfaceProps, "variant"> {
  divided?: boolean
  tone?: SectionTone
}

const SECTION_TONE_VARIANTS: Record<SectionTone, SurfaceVariant> = {
  default: "panel",
  subtle: "subtle",
  danger: "danger",
  warning: "warning",
  success: "success"
}

function Root({ children, className = "", divided = false, padding = "md", tone = "default", ...props }: SectionRootProps) {
  return (
    <section className={surfaceClasses(SECTION_TONE_VARIANTS[tone], padding, classes(divided && "divide-y divide-border", className))} data-section-divided={divided ? "true" : undefined} {...props}>
      {children}
    </section>
  )
}

function Header({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("flex flex-wrap items-start justify-between gap-3", className)} {...props} />
}

function Title({ className = "", ...props }: TextProps<"h2">) {
  return <Text as="h2" className={classes("text-[length:var(--text-section-title)]", className)} variant="heading-sm" {...props} />
}

function Description({ className = "", ...props }: TextProps<"p">) {
  return <Text className={classes("mt-1", className)} muted {...props} />
}

function Actions({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("flex flex-wrap items-center gap-2", className)} {...props} />
}

function Body({ className = "", padding = "none", ...props }: HTMLAttributes<HTMLDivElement> & { padding?: SurfacePadding }) {
  const paddingClass = padding === "none" ? "" : padding === "sm" ? "pt-[var(--space-section-compact)]" : padding === "md" ? "pt-[var(--space-section)]" : "pt-6"
  return <div className={classes(paddingClass, className)} {...props} />
}

export const Section = {
  Root,
  Header,
  Title,
  Description,
  Actions,
  Body
}
