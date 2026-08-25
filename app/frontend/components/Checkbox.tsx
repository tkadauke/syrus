import { forwardRef } from "react"
import type { InputHTMLAttributes, ReactNode } from "react"

export interface CheckboxProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "type"> {
  label?: ReactNode
}

// Shared checkbox primitive, token-styled to match Input/Select/Button.
// Wrapping the native <input> in a <label> (rather than requiring a
// caller-supplied `id`/`htmlFor` pair) associates the label implicitly.
export const Checkbox = forwardRef<HTMLInputElement, CheckboxProps>(function Checkbox(
  { label, className = "", ...props },
  ref
) {
  const input = (
    <input
      className={`h-4 w-4 shrink-0 rounded border-border text-brand accent-brand focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950 ${className}`.trim()}
      ref={ref}
      type="checkbox"
      {...props}
    />
  )

  if (!label) return input

  return (
    <label className="inline-flex items-center gap-2 text-sm text-text-primary">
      {input}
      <span>{label}</span>
    </label>
  )
})
