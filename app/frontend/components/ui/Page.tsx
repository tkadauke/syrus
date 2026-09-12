import type { HTMLAttributes } from "react"
import { classes } from "./classes"
import { Text } from "./Text"
import type { TextProps } from "./Text"

export type PageSize = "narrow" | "default" | "wide" | "full"
export type PageGutter = "always" | "responsive"

export interface PageRootProps extends HTMLAttributes<HTMLElement> {
  size?: PageSize
  /**
   * "always" (default) applies `--space-page-x`/`-y` at every viewport.
   * "responsive" drops the gutter below `sm:` so mobile content can run
   * edge to edge; a caller that wants this must not also pass its own
   * px/py override in `className` -- plain string concatenation can't
   * guarantee which of two conflicting utilities for the same property
   * wins, so this prop is the only supported way to get flush mobile
   * edges.
   */
  gutter?: PageGutter
}

const PAGE_SIZE_CLASSES: Record<PageSize, string> = {
  narrow: "max-w-4xl",
  default: "max-w-6xl",
  wide: "max-w-[96rem]",
  full: "max-w-none"
}

const PAGE_GUTTER_CLASSES: Record<PageGutter, string> = {
  always: "px-[var(--space-page-x)] py-[var(--space-page-y)]",
  responsive: "px-0 py-4 sm:px-[var(--space-page-x)] sm:py-[var(--space-page-y)]"
}

function Root({ size = "default", gutter = "always", className = "", ...props }: PageRootProps) {
  return <main className={classes("mx-auto w-full space-y-6", PAGE_GUTTER_CLASSES[gutter], PAGE_SIZE_CLASSES[size], className)} {...props} />
}

function Header({ className = "", ...props }: HTMLAttributes<HTMLElement>) {
  return <header className={classes("flex flex-wrap items-start justify-between gap-4", className)} {...props} />
}

function HeadingGroup({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("min-w-0 space-y-1", className)} {...props} />
}

function Title({ className = "", ...props }: TextProps<"h1">) {
  return <Text as="h1" className={classes("text-[length:var(--text-page-title)] leading-tight", className)} variant="heading-md" {...props} />
}

function Description({ className = "", ...props }: TextProps<"p">) {
  return <Text className={className} muted {...props} />
}

function Actions({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("flex flex-wrap items-center gap-2", className)} {...props} />
}

export const Page = {
  Root,
  Header,
  HeadingGroup,
  Title,
  Description,
  Actions
}
