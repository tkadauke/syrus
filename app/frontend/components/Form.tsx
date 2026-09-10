import type { HTMLAttributes, LabelHTMLAttributes, ReactNode } from "react"

export function FormField({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`space-y-2 ${className}`.trim()} {...props} />
}

export function FormLabel({ className = "", ...props }: LabelHTMLAttributes<HTMLLabelElement>) {
  return <label className={`block text-sm font-medium text-text-primary ${className}`.trim()} {...props} />
}

export function FormHelpText({ className = "", ...props }: HTMLAttributes<HTMLParagraphElement>) {
  return <p className={`text-xs text-text-secondary ${className}`.trim()} {...props} />
}

export function FormErrorText({ children, className = "", ...props }: HTMLAttributes<HTMLParagraphElement> & { children?: ReactNode }) {
  if (!children) return null

  return (
    <p className={`text-xs font-medium text-danger ${className}`.trim()} {...props}>
      {children}
    </p>
  )
}

export function FormActions({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`flex flex-wrap items-center justify-end gap-2 ${className}`.trim()} {...props} />
}
