import { forwardRef } from "react"
import type { InputHTMLAttributes, ReactNode } from "react"

export interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type"> {
  invalid?: boolean
  label?: ReactNode
}

// Shared checkbox primitive, token-styled to match Input/Select/Button.
// Wrapping the native <input> in a <label> (rather than requiring a
// caller-supplied `id`/`htmlFor` pair) associates the label implicitly.
export const Checkbox = forwardRef<HTMLInputElement, CheckboxProps>(function Checkbox(
  { invalid = false, label, className = "", ...props },
  ref
) {
  const input = (
    <input
      aria-invalid={invalid || undefined}
      className={`h-4 w-4 shrink-0 rounded focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950 ${
        invalid ? "border-danger text-danger accent-danger focus-visible:ring-danger" : "border-border text-brand accent-brand focus-visible:ring-brand"
      } ${className}`.trim()}
      ref={ref}
      type="checkbox"
      {...props}
    />
  )

  if (!label) return input

  return (
    <label className="flex items-center gap-2 text-sm text-text-primary">
      {input}
      <span>{label}</span>
    </label>
  )
})
