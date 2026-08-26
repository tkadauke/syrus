import { forwardRef } from "react"
import type { SelectHTMLAttributes } from "react"

export interface SelectProps extends SelectHTMLAttributes<HTMLSelectElement> {
  invalid?: boolean
  fullWidth?: boolean
}

// Shared native <select> primitive, token-styled to match Input/Button.
// Native <select> (rather than the toolbar button+listbox pattern) is the
// right call here — see CLAUDE.md's "Toolbar dropdown controls" convention.
//
// fullWidth defaults to true; pass fullWidth={false} for inline/compact
// controls (e.g. a per-row role <select>) instead of appending "w-auto" at
// the call site -- Tailwind's generated stylesheet orders "w-full" after
// "w-auto", so an appended "w-auto" loses the specificity tie and the
// element silently stays full width.
export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { invalid = false, fullWidth = true, className = "", children, ...props },
  ref
) {
  return (
    <select
      aria-invalid={invalid || undefined}
      className={`block ${fullWidth ? "w-full" : "w-auto"} rounded-md border bg-surface px-3 py-2 text-sm text-text-primary focus:outline-none focus:ring-1 disabled:cursor-not-allowed disabled:opacity-60 ${
        invalid ? "border-danger focus:border-danger focus:ring-danger" : "border-border focus:border-brand focus:ring-brand"
      } ${className}`.trim()}
      ref={ref}
      {...props}
    >
      {children}
    </select>
  )
})
