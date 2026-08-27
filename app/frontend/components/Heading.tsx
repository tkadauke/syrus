import type { ComponentPropsWithoutRef, ElementType, ReactNode } from "react"

/*
 * Shared heading scale (design-system convention).
 *
 * `PageHeading` is the canonical `<h1>` for a route: text-2xl font-semibold.
 * `SectionHeading` is the canonical section title within a route: text-base
 * font-semibold, rendered as `<h2>` by default (pass `as="h3"` for a
 * sub-section nested under another SectionHeading).
 *
 * Both replace what used to be an ad hoc mix of sizes for structurally
 * identical headers (page titles ranging text-base..text-3xl; section
 * titles ranging text-sm..text-lg, all still "font-semibold"). Adopt these
 * incrementally in routes you're already touching rather than doing a
 * repo-wide rewrite in one pass.
 */

const PAGE_HEADING_CLASS = "text-2xl font-semibold text-gray-900 dark:text-gray-100"
const SECTION_HEADING_CLASS = "text-base font-semibold text-gray-900 dark:text-gray-100"

type PageHeadingProps = { children: ReactNode; className?: string; mono?: boolean } & Omit<ComponentPropsWithoutRef<"h1">, "className" | "children">

export function PageHeading({ children, className = "", mono = false, ...rest }: PageHeadingProps) {
  return (
    <h1 className={[PAGE_HEADING_CLASS, mono ? "break-words font-mono" : "", className].filter(Boolean).join(" ")} {...rest}>
      {children}
    </h1>
  )
}

type SectionHeadingProps = { children: ReactNode; className?: string; as?: ElementType } & Omit<ComponentPropsWithoutRef<"h2">, "className" | "children">

export function SectionHeading({ children, className = "", as = "h2", ...rest }: SectionHeadingProps) {
  const Tag = as
  return (
    <Tag className={[SECTION_HEADING_CLASS, className].filter(Boolean).join(" ")} {...rest}>
      {children}
    </Tag>
  )
}
