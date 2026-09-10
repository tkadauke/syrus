import type { AnchorHTMLAttributes, ReactNode } from "react"
import { Link } from "react-router-dom"
import type { LinkProps } from "react-router-dom"
import { classes } from "./classes"

type LinkTextBaseProps = {
  children?: ReactNode
  className?: string
  external?: boolean
}

type RouterLinkTextProps = LinkTextBaseProps & LinkProps & { href?: never }
type AnchorLinkTextProps = LinkTextBaseProps & AnchorHTMLAttributes<HTMLAnchorElement> & { to?: never }

export type LinkTextProps = RouterLinkTextProps | AnchorLinkTextProps

export function linkTextClasses(className = "") {
  return classes("font-medium text-link underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2", className)
}

export function LinkText({ className = "", external = false, ...props }: LinkTextProps) {
  const mergedClassName = linkTextClasses(className)

  if ("to" in props && props.to !== undefined) {
    return <Link className={mergedClassName} {...props} />
  }

  const anchorProps = props as AnchorLinkTextProps
  return (
    <a
      className={mergedClassName}
      {...anchorProps}
      rel={external ? "noreferrer" : anchorProps.rel}
      target={external ? "_blank" : anchorProps.target}
    />
  )
}
