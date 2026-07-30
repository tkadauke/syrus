import { useQuery } from "@tanstack/react-query"
import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { fetchPickerEpics, type PickerEpicRecord } from "../../api/epics"
import { fetchPickerJobs, type PickerJobRecord } from "../../api/jobs"
import { useT } from "../../hooks/useT"

type PickerItem = {
  id: number
  label: string
  title: string
  statePriority: number
}

function jobStatePriority(state: string): number {
  if (state === "implemented") return 0
  if (state === "closed") return 1
  if (state === "approved" || state === "landing") return 2
  if (state === "open" || state === "queued" || state === "triaging") return 3
  return 4
}

function toJobItem(job: PickerJobRecord): PickerItem {
  return { id: job.id, label: `JOB-${job.id}`, title: job.title || job.issue_title, statePriority: jobStatePriority(job.state) }
}

function toEpicItem(epic: PickerEpicRecord): PickerItem {
  return { id: epic.id, label: `EPIC-${epic.number}`, title: epic.title, statePriority: 0 }
}

export function JobEpicPickerPopup({
  kind,
  repositorySlug,
  filterByPr,
  onSelect,
  onCancel
}: {
  kind: "job" | "epic"
  repositorySlug: string | null
  filterByPr?: boolean
  onSelect: (id: string) => void
  onCancel: () => void
}) {
  const { t } = useT("chat")
  const [query, setQuery] = useState("")
  const [activeIndex, setActiveIndex] = useState(0)
  const inputRef = useRef<HTMLInputElement | null>(null)

  const jobsQuery = useQuery({
    queryKey: ["picker-jobs", repositorySlug],
    queryFn: () => fetchPickerJobs({ repo: repositorySlug ?? undefined, limit: 50 }),
    enabled: kind === "job",
    staleTime: 30_000
  })

  const epicsQuery = useQuery({
    queryKey: ["picker-epics", repositorySlug],
    queryFn: () => fetchPickerEpics({ repo: repositorySlug ?? undefined, limit: 50 }),
    enabled: kind === "epic",
    staleTime: 30_000
  })

  const isLoading = kind === "job" ? jobsQuery.isLoading : epicsQuery.isLoading

  const allItems = useMemo<PickerItem[]>(() => {
    if (kind === "job") {
      const jobs = jobsQuery.data?.jobs ?? []
      const visibleJobs = filterByPr ? jobs.filter((j) => j.pr_url != null) : jobs
      return visibleJobs.map(toJobItem).sort((a, b) => a.statePriority - b.statePriority)
    }
    return (epicsQuery.data?.epics ?? []).map(toEpicItem)
  }, [kind, jobsQuery.data, epicsQuery.data, filterByPr])

  const filteredItems = useMemo<PickerItem[]>(() => {
    if (!query.trim()) return allItems
    const lower = query.toLowerCase()
    return allItems.filter(
      (item) => item.title.toLowerCase().includes(lower) || item.label.toLowerCase().includes(lower)
    )
  }, [allItems, query])

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  useEffect(() => {
    setActiveIndex(0)
  }, [filteredItems.length])

  const activeItemRef = useCallback((node: HTMLButtonElement | null) => {
    node?.scrollIntoView?.({ block: "nearest" })
  }, [])

  function handleKeyDown(event: React.KeyboardEvent<HTMLInputElement>) {
    if (event.key === "ArrowDown") {
      event.preventDefault()
      setActiveIndex((i) => Math.min(i + 1, filteredItems.length - 1))
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      setActiveIndex((i) => Math.max(i - 1, 0))
    } else if (event.key === "Enter") {
      event.preventDefault()
      const item = filteredItems[activeIndex]
      if (item) onSelect(String(item.id))
    } else if (event.key === "Escape") {
      event.preventDefault()
      onCancel()
    }
  }

  const searchPlaceholder = kind === "job" ? t("picker_search_jobs") : t("picker_search_epics")
  const emptyLabel = kind === "job"
    ? (filterByPr ? t("picker_no_jobs_with_pr") : t("picker_no_jobs"))
    : t("picker_no_epics")

  return (
    <div
      aria-label={t("aria_job_epic_picker")}
      className="absolute bottom-full left-3 right-3 z-10 mb-2 overflow-hidden rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950"
      id="chat-job-epic-picker"
      role="dialog"
    >
      <div className="border-b border-gray-100 p-2 dark:border-gray-800">
        <input
          aria-autocomplete="list"
          aria-controls="chat-job-epic-picker-list"
          aria-expanded="true"
          className="w-full rounded border border-gray-200 bg-white px-2.5 py-1.5 text-sm placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500"
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={searchPlaceholder}
          ref={inputRef}
          role="combobox"
          type="text"
          value={query}
        />
      </div>
      <div
        className="max-h-60 overflow-y-auto overscroll-contain"
        id="chat-job-epic-picker-list"
        role="listbox"
      >
        {isLoading ? (
          <div className="px-3 py-4 text-center text-sm text-gray-400 dark:text-gray-500">
            {t("picker_loading")}
          </div>
        ) : filteredItems.length === 0 ? (
          <div className="px-3 py-4 text-center text-sm text-gray-400 dark:text-gray-500">
            {emptyLabel}
          </div>
        ) : (
          filteredItems.map((item, index) => {
            const active = index === activeIndex
            return (
              <button
                aria-selected={active}
                className={`flex w-full items-baseline gap-3 px-3 py-2 text-left text-sm ${active ? "bg-blue-50 dark:bg-blue-950" : "hover:bg-gray-50 dark:hover:bg-gray-900"}`}
                key={item.id}
                onClick={() => onSelect(String(item.id))}
                onMouseDown={(event) => event.preventDefault()}
                ref={active ? activeItemRef : null}
                role="option"
                type="button"
              >
                <span className="shrink-0 font-mono text-xs font-semibold text-gray-500 dark:text-gray-400">
                  {item.label}
                </span>
                <span className="min-w-0 truncate text-gray-900 dark:text-gray-100">{item.title}</span>
              </button>
            )
          })
        )}
      </div>
    </div>
  )
}
