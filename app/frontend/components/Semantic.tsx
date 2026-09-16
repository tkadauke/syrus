import { forwardRef } from "react"
import type { HTMLAttributes, TableHTMLAttributes, TdHTMLAttributes, ThHTMLAttributes } from "react"

type Tone = "muted" | "info" | "success" | "warning" | "error"
type TextTone = "primary" | "secondary" | "muted" | "danger" | "success" | "warning"
type TextSize = "xs" | "sm" | "base" | "lg"

const noticeToneClasses: Record<Tone, string> = {
  muted: "border-border bg-surface text-text-secondary",
  info: "border-info/30 bg-info/10 text-info",
  success: "border-success/30 bg-success/10 text-success",
  warning: "border-warning/30 bg-warning/10 text-warning",
  error: "border-danger/30 bg-danger/10 text-danger"
}

const textToneClasses: Record<TextTone, string> = {
  primary: "text-text-primary",
  secondary: "text-text-secondary",
  muted: "text-text-muted",
  danger: "text-danger",
  success: "text-success",
  warning: "text-warning"
}

const textSizeClasses: Record<TextSize, string> = {
  xs: "text-xs",
  sm: "text-sm",
  base: "text-base",
  lg: "text-lg"
}

export const Section = forwardRef<HTMLElement, HTMLAttributes<HTMLElement> & { as?: "article" | "form" | "section" | "ul" }>(function Section(
  { as: Component = "section", className = "", ...props },
  ref
) {
  const Element = Component as "section"
  return <Element className={`rounded border border-border bg-surface p-4 ${className}`.trim()} ref={ref} {...props} />
})

export function Notice({ className = "", tone = "muted", ...props }: HTMLAttributes<HTMLDivElement> & { tone?: Tone }) {
  return <div className={`rounded border p-4 text-sm ${noticeToneClasses[tone]} ${className}`.trim()} {...props} />
}

export function Toolbar({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`flex flex-wrap items-center gap-2 ${className}`.trim()} {...props} />
}

export function Text({ as: Component = "p", className = "", size = "sm", tone = "secondary", ...props }: HTMLAttributes<HTMLElement> & { as?: "dd" | "dt" | "p" | "span"; size?: TextSize; tone?: TextTone }) {
  return <Component className={`${textSizeClasses[size]} ${textToneClasses[tone]} ${className}`.trim()} {...props} />
}

export function TableSurface({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`overflow-x-auto rounded border border-border bg-surface ${className}`.trim()} {...props} />
}

export function DataTable({ className = "", ...props }: TableHTMLAttributes<HTMLTableElement>) {
  return <table className={`min-w-full divide-y divide-border ${className}`.trim()} {...props} />
}

export function DataTableHead({ className = "", ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return <thead className={`bg-surface-raised text-left text-xs font-medium uppercase text-text-muted ${className}`.trim()} {...props} />
}

export function DataTableBody({ className = "", ...props }: HTMLAttributes<HTMLTableSectionElement>) {
  return <tbody className={`divide-y divide-border text-sm ${className}`.trim()} {...props} />
}

export function DataTableHeader({ className = "", ...props }: ThHTMLAttributes<HTMLTableCellElement>) {
  return <th className={`px-4 py-2 ${className}`.trim()} {...props} />
}

export function DataTableCell({ className = "", ...props }: TdHTMLAttributes<HTMLTableCellElement>) {
  return <td className={`px-4 py-3 ${className}`.trim()} {...props} />
}

export function DescriptionList({ className = "", ...props }: HTMLAttributes<HTMLDListElement>) {
  return <dl className={`space-y-2 text-sm ${className}`.trim()} {...props} />
}

export function DescriptionRow({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`flex items-start justify-between gap-3 border-b border-border pb-2 last:border-0 ${className}`.trim()} {...props} />
}
