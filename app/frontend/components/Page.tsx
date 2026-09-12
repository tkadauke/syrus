import type { HTMLAttributes } from "react"

export type PageSize = "narrow" | "default" | "wide" | "full"

const PAGE_SIZE_CLASSES: Record<PageSize, string> = {
  narrow: "max-w-3xl",
  default: "max-w-5xl",
  wide: "max-w-[96rem]",
  full: "max-w-none"
}

export function Page({ className = "", size = "default", ...props }: HTMLAttributes<HTMLElement> & { size?: PageSize }) {
  return <main className={`mx-auto ${PAGE_SIZE_CLASSES[size]} space-y-6 p-6 ${className}`.trim()} {...props} />
}

export function PageHeader({ className = "", ...props }: HTMLAttributes<HTMLElement>) {
  return <header className={`space-y-1 ${className}`.trim()} {...props} />
}

export function PageDescription({ className = "", ...props }: HTMLAttributes<HTMLParagraphElement>) {
  return <p className={`text-sm text-text-secondary ${className}`.trim()} {...props} />
}
