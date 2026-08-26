import { forwardRef } from "react"
import type { InputHTMLAttributes } from "react"

export interface InputProps extends InputHTMLAttributes<HTMLInputElement> {
  invalid?: boolean
  fullWidth?: boolean
}

// Shared text-input primitive, token-styled to match Button/Select/Checkbox
// (see app/assets/tailwind/application.css for the semantic color tokens).
//
// fullWidth defaults to true; pass fullWidth={false} for inline/compact
// controls instead of appending "w-auto" at the call site -- Tailwind's
// generated stylesheet orders "w-full" after "w-auto", so an appended
// "w-auto" loses the specificity tie and the element silently stays full
// width.
export const Input = forwardRef<HTMLInputElement, InputProps>(function Input(
  { invalid = false, fullWidth = true, className = "", ...props },
  ref
) {
  return (
    <input
      aria-invalid={invalid || undefined}
      className={`block ${fullWidth ? "w-full" : "w-auto"} rounded-md border bg-surface px-3 py-2 text-sm text-text-primary placeholder:text-text-secondary focus:outline-none focus:ring-1 disabled:cursor-not-allowed disabled:opacity-60 ${
        invalid ? "border-danger focus:border-danger focus:ring-danger" : "border-border focus:border-brand focus:ring-brand"
      } ${className}`.trim()}
      ref={ref}
      {...props}
    />
  )
})
