import type { HTMLAttributes } from "react"
import { classes } from "./classes"
import { Text } from "./Text"
import type { TextProps } from "./Text"

export type PageSize = "narrow" | "default" | "wide" | "full"

export interface PageRootProps extends HTMLAttributes<HTMLElement> {
  size?: PageSize
}

const PAGE_SIZE_CLASSES: Record<PageSize, string> = {
  narrow: "max-w-4xl",
  default: "max-w-6xl",
  wide: "max-w-[96rem]",
  full: "max-w-none"
}

function Root({ size = "default", className = "", ...props }: PageRootProps) {
  return <main className={classes("mx-auto w-full space-y-6 px-[var(--space-page-x)] py-[var(--space-page-y)]", PAGE_SIZE_CLASSES[size], className)} {...props} />
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
