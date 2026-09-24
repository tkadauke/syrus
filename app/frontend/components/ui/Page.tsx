import { createContext, useContext } from "react"
import type { HTMLAttributes } from "react"
import { classes } from "./classes"
import { Text } from "./Text"
import type { TextProps } from "./Text"

export type PageSize = "form" | "narrow" | "medium" | "default" | "large" | "wide" | "extra-wide" | "full"
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
  form: "max-w-3xl",
  narrow: "max-w-4xl",
  medium: "max-w-5xl",
  default: "max-w-6xl",
  large: "max-w-7xl",
  wide: "max-w-[96rem]",
  "extra-wide": "max-w-[100rem]",
  full: "max-w-none"
}

const PAGE_GUTTER_CLASSES: Record<PageGutter, string> = {
  always: "px-[var(--space-page-x)] py-[var(--space-page-y)]",
  responsive: "px-0 py-4 sm:px-[var(--space-page-x)] sm:py-[var(--space-page-y)]"
}

/**
 * The gutter a Page.Root was given, exposed to its subtree so header-ish
 * content (Page.Header, Page.Nav, or a caller's own banner/pagination
 * markup) can restore the horizontal inset a "responsive" root drops below
 * `sm:` without every consumer hand-writing the same `px-4 sm:px-0` /
 * `mx-4 sm:mx-0` class. Defaults to "always" (a no-op restore) so a
 * subcomponent rendered outside a Page.Root -- e.g. in isolation in a test --
 * behaves the same as it did before this context existed.
 */
const PageGutterContext = createContext<PageGutter>("always")

export function usePageGutter(): PageGutter {
  return useContext(PageGutterContext)
}

const GUTTER_RESTORE_CLASSES: Record<"padding" | "margin", Record<PageGutter, string>> = {
  padding: { always: "", responsive: "px-4 sm:px-0" },
  margin: { always: "", responsive: "mx-4 sm:mx-0" }
}

/**
 * The class that restores a fixed mobile inset for content that sits flush
 * against a "responsive" Page.Root's edge-to-edge body -- headers, nav/tab
 * bars, and other banner-like content that should keep the page's normal
 * margin even though the main content runs edge to edge. Empty string (a
 * no-op) under gutter="always", since the root itself already carries the
 * margin there.
 */
export function usePageGutterRestoreClassName(kind: "padding" | "margin" = "padding"): string {
  return GUTTER_RESTORE_CLASSES[kind][usePageGutter()]
}

function Root({ size = "default", gutter = "always", className = "", ...props }: PageRootProps) {
  return (
    <PageGutterContext.Provider value={gutter}>
      <main className={classes("mx-auto w-full space-y-6", PAGE_GUTTER_CLASSES[gutter], PAGE_SIZE_CLASSES[size], className)} {...props} />
    </PageGutterContext.Provider>
  )
}

function Header({ className = "", ...props }: HTMLAttributes<HTMLElement>) {
  const restore = usePageGutterRestoreClassName("padding")
  return <header className={classes("flex flex-wrap items-start justify-between gap-4", restore, className)} {...props} />
}

/**
 * For tab/section-nav bars that sit directly under a page header -- like
 * Page.Header, they're conceptually part of the page chrome rather than the
 * main content, so a "responsive" root's mobile margin restores here too.
 */
function Nav({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  const restore = usePageGutterRestoreClassName("padding")
  return <div className={classes(restore, className)} {...props} />
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
  Nav,
  HeadingGroup,
  Title,
  Description,
  Actions
}
