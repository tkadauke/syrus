import { forwardRef } from "react"
import type { TextareaHTMLAttributes } from "react"

export interface TextareaProps extends TextareaHTMLAttributes<HTMLTextAreaElement> {
  invalid?: boolean
  fullWidth?: boolean
}

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaProps>(function Textarea(
  { invalid = false, fullWidth = true, className = "", ...props },
  ref
) {
  return (
    <textarea
      aria-invalid={invalid || undefined}
      className={`block min-h-[calc(var(--control-height-md)*2)] ${fullWidth ? "w-full" : "w-auto"} rounded-[var(--radius-control)] border border-[length:var(--border-width)] bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-secondary focus:outline-none focus:ring-1 disabled:cursor-not-allowed disabled:opacity-60 ${
        invalid ? "border-danger focus:border-danger focus:ring-danger" : "border-border focus:border-brand focus:ring-brand"
      } ${className}`.trim()}
      ref={ref}
      {...props}
    />
  )
})
