import type { HTMLAttributes } from "react"
import { classes } from "./classes"

export type LayoutGap = "none" | "xs" | "sm" | "md" | "lg"
export type LayoutAlign = "start" | "center" | "end" | "stretch"
export type LayoutJustify = "start" | "center" | "end" | "between"

const GAP_CLASSES: Record<LayoutGap, string> = {
  none: "gap-0",
  xs: "gap-1.5",
  sm: "gap-2",
  md: "gap-3",
  lg: "gap-4"
}

const STACK_GAP_CLASSES: Record<LayoutGap, string> = {
  none: "space-y-0",
  xs: "space-y-1.5",
  sm: "space-y-2",
  md: "space-y-3",
  lg: "space-y-4"
}

const ALIGN_CLASSES: Record<LayoutAlign, string> = {
  start: "items-start",
  center: "items-center",
  end: "items-end",
  stretch: "items-stretch"
}

const JUSTIFY_CLASSES: Record<LayoutJustify, string> = {
  start: "justify-start",
  center: "justify-center",
  end: "justify-end",
  between: "justify-between"
}

export interface StackProps extends HTMLAttributes<HTMLDivElement> {
  gap?: LayoutGap
}

export function Stack({ gap = "md", className = "", ...props }: StackProps) {
  return <div className={classes(STACK_GAP_CLASSES[gap], className)} {...props} />
}

export interface InlineProps extends HTMLAttributes<HTMLDivElement> {
  align?: LayoutAlign
  gap?: LayoutGap
  justify?: LayoutJustify
  wrap?: boolean
}

export function Inline({ align = "center", gap = "sm", justify = "start", wrap = false, className = "", ...props }: InlineProps) {
  return <div className={classes("flex", ALIGN_CLASSES[align], JUSTIFY_CLASSES[justify], GAP_CLASSES[gap], wrap && "flex-wrap", className)} {...props} />
}

export interface ClusterProps extends HTMLAttributes<HTMLDivElement> {
  align?: LayoutAlign
  gap?: LayoutGap
  justify?: LayoutJustify
}

export function Cluster({ align = "center", gap = "sm", justify = "start", className = "", ...props }: ClusterProps) {
  return <div className={classes("flex flex-wrap", ALIGN_CLASSES[align], JUSTIFY_CLASSES[justify], GAP_CLASSES[gap], className)} {...props} />
}

export interface ToolbarProps extends HTMLAttributes<HTMLDivElement> {
  align?: LayoutAlign
  gap?: LayoutGap
  justify?: LayoutJustify
}

export function Toolbar({ align = "center", gap = "sm", justify = "between", className = "", role = "toolbar", ...props }: ToolbarProps) {
  return <div className={classes("flex flex-wrap", ALIGN_CLASSES[align], JUSTIFY_CLASSES[justify], GAP_CLASSES[gap], className)} role={role} {...props} />
}
