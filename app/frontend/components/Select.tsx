import { forwardRef } from "react"
import type { SelectHTMLAttributes } from "react"

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  invalid?: boolean
}

// Shared native <select> primitive, token-styled to match Input/Button.
// Native <select> (rather than the toolbar button+listbox pattern) is the
// right call here — see CLAUDE.md's "Toolbar dropdown controls" convention.
export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { invalid = false, className = "", children, ...props },
  ref
) {
  return (
    <select
      aria-invalid={invalid || undefined}
      className={`block w-full rounded-md border bg-surface px-3 py-2 text-sm text-text-primary focus:outline-none focus:ring-1 disabled:cursor-not-allowed disabled:opacity-60 ${
        invalid ? "border-danger focus:border-danger focus:ring-danger" : "border-border focus:border-brand focus:ring-brand"
      } ${className}`.trim()}
      ref={ref}
      {...props}
    >
      {children}
    </select>
  )
})
