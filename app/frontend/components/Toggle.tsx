import { forwardRef } from "react"
import type { ButtonHTMLAttributes, ReactNode } from "react"

export interface ToggleProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "onChange" | "value" | "type"> {
  checked: boolean
  invalid?: boolean
  onChange: (checked: boolean) => void
  label?: ReactNode
}

// Shared on/off switch primitive, token-styled to match Checkbox/Input.
// A native <button role="switch"> (not a styled checkbox) — the standard
// accessible pattern for a toggle. Wrapping in a <label> (button is a
// labelable element) works the same way Checkbox wraps its <input>.
export const Toggle = forwardRef<HTMLButtonElement, ToggleProps>(function Toggle(
  { checked, invalid = false, onChange, label, className = "", disabled, ...props },
  ref
) {
  const button = (
    <button
      aria-checked={checked}
      aria-invalid={invalid || undefined}
      className={`relative inline-flex h-6 w-11 shrink-0 items-center rounded-full transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950 ${
        checked ? "bg-brand" : "bg-border"
      } ${invalid ? "ring-1 ring-danger focus-visible:ring-danger" : "focus-visible:ring-brand"} ${className}`.trim()}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      ref={ref}
      role="switch"
      type="button"
      {...props}
    >
      <span
        aria-hidden="true"
        className={`inline-block h-4 w-4 transform rounded-full bg-white transition-transform ${checked ? "translate-x-6" : "translate-x-1"}`}
      />
    </button>
  )

  if (!label) return button

  return (
    <label className="flex items-center gap-2 text-sm text-text-primary">
      <span>{label}</span>
      {button}
    </label>
  )
})
