import { type FormEvent, type ReactNode, useMemo } from "react"

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

export function compactInputClass() {
  return "block h-9 w-full rounded border border-gray-300 bg-white px-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-600 dark:bg-gray-950 dark:text-gray-100"
}

export type AdminEventFilterField = {
  name: string
  label: string
  placeholder?: string
  defaultValue?: string
  inputMode?: "numeric"
  options?: Array<{ label: string; value: string }>
}

export function AdminEventFilterBar({
  fields,
  onNavigate,
  search,
  searchLabel,
  clearLabel
}: {
  fields: AdminEventFilterField[]
  onNavigate: (params: URLSearchParams) => void
  search: string
  searchLabel: string
  clearLabel: string
}) {
  const params = useMemo(() => new URLSearchParams(search), [search])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    const next = new URLSearchParams()

    for (const field of fields) {
      const value = String(form.get(field.name) || "").trim()
      if (value) next.set(field.name, value)
    }
    onNavigate(next)
  }

  function clear() {
    onNavigate(new URLSearchParams())
  }

  return (
    <form className="flex flex-wrap items-center gap-2 text-sm" onSubmit={submit}>
      {fields.map((field) => (
        <label className="inline-flex min-h-10 items-center gap-2 rounded border border-gray-300 bg-white px-2.5 py-1.5 text-gray-700 shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200" key={field.name}>
          <span className="whitespace-nowrap text-xs font-medium text-gray-500 dark:text-gray-400">{field.label} is</span>
          {field.options ? (
            <select className={adminEventFilterInputClass()} defaultValue={params.get(field.name) || field.defaultValue || ""} name={field.name}>
              {field.options.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          ) : (
            <input
              className={adminEventFilterInputClass()}
              defaultValue={params.get(field.name) || field.defaultValue || ""}
              inputMode={field.inputMode}
              name={field.name}
              placeholder={field.placeholder}
            />
          )}
        </label>
      ))}
      <button className="inline-flex min-h-10 items-center justify-center rounded bg-gray-900 px-3 py-1.5 font-medium text-white hover:bg-gray-800 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-gray-200" type="submit">{searchLabel}</button>
      <button className="inline-flex min-h-10 items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800" onClick={clear} type="button">{clearLabel}</button>
    </form>
  )
}

function adminEventFilterInputClass() {
  return "min-w-0 max-w-56 border-0 bg-transparent p-0 text-sm font-medium text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-0 dark:text-gray-100 dark:placeholder:text-gray-500"
}

export function pageButtonClass() {
  return "inline-flex items-center justify-center rounded border border-gray-300 bg-white px-3 py-1.5 font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-500"
}

export function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
}

export function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-400 dark:border-gray-800 dark:text-gray-600"
}

export function adminEventLinkClass() {
  return "text-blue-600 underline hover:no-underline dark:text-blue-300"
}

export function severityPillClass(severity: string) {
  if (severity === "alarm" || severity === "error") return "bg-red-100 text-red-700 dark:bg-red-950/60 dark:text-red-300"
  if (severity === "warn") return "bg-amber-100 text-amber-700 dark:bg-amber-950/60 dark:text-amber-300"
  return "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
}

export function durationLabel(value: number | null) {
  if (value == null) return "-"
  if (value >= 60_000) return `${(value / 60_000).toFixed(1)}m`
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)}s`
  return `${Math.round(value)}ms`
}

export function AdminEventTextFilter({ defaultValue, inputMode, label, name }: { defaultValue: string; inputMode?: "numeric"; label: string; name: string }) {
  return (
    <label className="space-y-1">
      <span className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</span>
      <input className={compactInputClass()} defaultValue={defaultValue} inputMode={inputMode} name={name} />
    </label>
  )
}

export type AdminEventTimelineBucket = {
  start_at: string
  end_at: string
  count: number
}

export function AdminEventTimeline({ buckets, emptyLabel, title }: { buckets: AdminEventTimelineBucket[]; emptyLabel: string; title: string }) {
  const max = Math.max(0, ...buckets.map((bucket) => bucket.count))
  if (buckets.length === 0 || max === 0) {
    return <AdminEventPanelMessage>{emptyLabel}</AdminEventPanelMessage>
  }

  return (
    <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h2>
      <div className="mt-4 flex h-28 items-end gap-1">
        {buckets.map((bucket) => (
          <div className="group relative flex min-w-1 flex-1 items-end" key={bucket.start_at}>
            <div
              aria-label={`${bucket.count} events from ${formatEventDate(bucket.start_at)} to ${formatEventDate(bucket.end_at)}`}
              className="w-full rounded-t bg-terracotta-500/70 transition-colors group-hover:bg-terracotta-600"
              style={{ height: `${Math.max(4, (bucket.count / max) * 100)}%` }}
              title={`${bucket.count} · ${formatEventDate(bucket.start_at)}`}
            />
          </div>
        ))}
      </div>
    </section>
  )
}

export function formatEventDate(value: string | null | undefined) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

export function shortRevision(value: string | null | undefined) {
  if (!value) return "-"
  return value.length > 12 ? value.slice(0, 12) : value
}

export function DetailBlock({ title, value }: { title: string; value?: string | null }) {
  return (
    <section>
      <h3 className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{title}</h3>
      <pre className="mt-2 max-h-80 overflow-auto rounded border border-gray-200 bg-white p-3 text-xs leading-5 text-gray-800 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100">{value || "-"}</pre>
    </section>
  )
}

export function JsonBlock({ title, value }: { title: string; value: unknown }) {
  return <DetailBlock title={title} value={JSON.stringify(value, null, 2)} />
}
