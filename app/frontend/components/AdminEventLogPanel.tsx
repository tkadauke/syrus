import { type ReactNode } from "react"

export function AdminEventPanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "warn" }) {
  const toneClass = tone === "error"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300"
    : tone === "warn"
      ? "border-amber-200 bg-amber-50 text-amber-800 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  return <div className={`rounded border p-4 text-sm ${toneClass}`}>{children}</div>
}

export function AdminEventPageShell({
  actions,
  ariaLabel,
  children,
  eyebrow,
  title
}: {
  actions?: ReactNode
  ariaLabel: string
  children: ReactNode
  eyebrow: string
  title: string
}) {
  return (
    <main aria-label={ariaLabel} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex flex-col gap-4 border-b border-gray-200 pb-4 dark:border-gray-700 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{eyebrow}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
        </div>
        {actions}
      </header>
      {children}
    </main>
  )
}

export function AdminEventPagination({
  label,
  nextLabel,
  onNavigate,
  pagination,
  previousLabel,
  search
}: {
  label: string
  nextLabel: string
  onNavigate: (params: URLSearchParams) => void
  pagination: {
    page: number
    has_next_page: boolean
    has_previous_page: boolean
    next_page?: number | null
    previous_page?: number | null
  }
  previousLabel: string
  search: string
}) {
  function go(page: number | null | undefined) {
    if (!page) return
    const params = new URLSearchParams(search)
    params.set("page", String(page))
    onNavigate(params)
  }

  return (
    <div className="flex items-center justify-between border-t border-gray-200 px-4 py-3 text-sm dark:border-gray-700">
      <button className={pageButtonClass()} disabled={!pagination.has_previous_page} onClick={() => go(pagination.previous_page)} type="button">{previousLabel}</button>
      <span className="text-gray-600 dark:text-gray-300">{label}</span>
      <button className={pageButtonClass()} disabled={!pagination.has_next_page} onClick={() => go(pagination.next_page)} type="button">{nextLabel}</button>
    </div>
  )
}

export function inputClass() {
  return "w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-gray-500 focus:outline-none focus:ring-1 focus:ring-gray-500 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
}

export function pageButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

export function formatEventDate(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export function shortRevision(value: string | null | undefined) {
  if (!value) return "-"
  return value.length > 12 ? value.slice(0, 12) : value
}
