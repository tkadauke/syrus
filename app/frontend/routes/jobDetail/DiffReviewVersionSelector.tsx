import { useEffect, useId, useMemo, useRef, useState } from "react"
import { useT } from "../../hooks/useT"
import type { DiffReviewVersion } from "../../api/jobs"
import type { TFunction } from "i18next"
import type { KeyboardEvent } from "react"

export function DiffReviewVersionSelector({
  disabled = false,
  latestVersionId,
  onChange,
  selectedVersionId,
  versions
}: {
  disabled?: boolean
  latestVersionId: number | null
  onChange: (versionId: number) => void
  selectedVersionId: number | null
  versions: DiffReviewVersion[]
}) {
  const { t } = useT("jobs")
  const listboxId = useId()
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([])
  const [open, setOpen] = useState(false)
  const ordered = useMemo(() => [...versions].sort(compareVersions), [versions])
  const selected = ordered.find((version) => version.id === selectedVersionId) || ordered[0] || null
  const selectedIndex = Math.max(0, ordered.findIndex((version) => version.id === selected?.id))
  const [activeIndex, setActiveIndex] = useState(selectedIndex)

  useEffect(() => {
    if (!open) setActiveIndex(selectedIndex)
  }, [open, selectedIndex])

  useEffect(() => {
    if (!open) return
    optionRefs.current[activeIndex]?.focus()
  }, [activeIndex, open])

  useEffect(() => {
    if (!open) return
    function onPointerDown(event: MouseEvent) {
      const target = event.target as Node
      if (buttonRef.current?.contains(target)) return
      if (optionRefs.current.some((option) => option?.contains(target))) return
      setOpen(false)
    }
    document.addEventListener("mousedown", onPointerDown)
    return () => document.removeEventListener("mousedown", onPointerDown)
  }, [open])

  if (ordered.length === 0) {
    return (
      <div className="rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-500 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
        {t("review_versions_empty")}
      </div>
    )
  }

  function selectVersion(version: DiffReviewVersion) {
    setOpen(false)
    onChange(version.id)
    buttonRef.current?.focus()
  }

  function moveActive(delta: number) {
    setActiveIndex((current) => (current + delta + ordered.length) % ordered.length)
  }

  function onButtonKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      setOpen(true)
      setActiveIndex(event.key === "ArrowDown" ? Math.min(selectedIndex + 1, ordered.length - 1) : Math.max(selectedIndex - 1, 0))
    }
  }

  function onOptionKeyDown(event: KeyboardEvent<HTMLButtonElement>, version: DiffReviewVersion) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      moveActive(event.key === "ArrowDown" ? 1 : -1)
    } else if (event.key === "Home") {
      event.preventDefault()
      setActiveIndex(0)
    } else if (event.key === "End") {
      event.preventDefault()
      setActiveIndex(ordered.length - 1)
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      selectVersion(version)
    } else if (event.key === "Escape") {
      event.preventDefault()
      setOpen(false)
      buttonRef.current?.focus()
    }
  }

  return (
    <div className="relative w-full min-w-0 max-w-full space-y-1 sm:max-w-xl">
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" id={`${listboxId}-label`}>
        {t("review_version_label")}
      </label>
      <button
        aria-controls={open ? listboxId : undefined}
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-labelledby={`${listboxId}-label ${listboxId}-button`}
        className="flex min-h-10 w-full min-w-0 items-center justify-between gap-2 rounded border border-gray-300 bg-white px-3 py-2 text-left text-sm text-gray-900 shadow-sm hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-brand/40 disabled:cursor-not-allowed disabled:bg-gray-50 disabled:text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:hover:bg-gray-800 dark:disabled:bg-gray-950 dark:disabled:text-gray-500"
        disabled={disabled || ordered.length <= 1}
        id={`${listboxId}-button`}
        onClick={() => setOpen((value) => !value)}
        onKeyDown={onButtonKeyDown}
        ref={buttonRef}
        type="button"
      >
        <span className="min-w-0 truncate">{selected ? collapsedLabel(t, selected) : t("review_version_label")}</span>
        <span aria-hidden="true" className="shrink-0 text-gray-400">v</span>
      </button>
      {open ? (
        <div
          aria-labelledby={`${listboxId}-label`}
          className="absolute left-0 z-30 mt-1 max-h-[min(22rem,70vh)] w-[min(100%,calc(100vw-2rem))] overflow-y-auto rounded border border-gray-200 bg-white p-1 shadow-lg dark:border-gray-700 dark:bg-gray-950"
          id={listboxId}
          role="listbox"
        >
          {ordered.map((version, index) => {
            const selectedOption = version.id === selected?.id
            const allChanges = isAllChangesVersion(version)
            return (
              <button
                aria-label={optionAccessibleName(t, version)}
                aria-selected={selectedOption}
                className={`block w-full rounded px-2.5 py-2 text-left text-sm focus:outline-none focus:ring-2 focus:ring-brand/40 ${selectedOption ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-900"} ${allChanges ? "border border-brand/30 bg-brand/5 font-medium" : ""}`}
                id={`${listboxId}-option-${version.id}`}
                key={version.id}
                onClick={() => selectVersion(version)}
                onKeyDown={(event) => onOptionKeyDown(event, version)}
                ref={(element) => { optionRefs.current[index] = element }}
                role="option"
                tabIndex={activeIndex === index ? 0 : -1}
                type="button"
              >
                {allChanges ? (
                  <AllChangesRow selected={selectedOption} t={t} version={version} />
                ) : (
                  <RangeRow selected={selectedOption} t={t} version={version} />
                )}
              </button>
            )
          })}
        </div>
      ) : null}
      {selected ? (
        <p className="max-w-3xl break-words text-xs text-gray-500 dark:text-gray-400">
          {versionMetadata(t, selected, selected.id === latestVersionId)}
        </p>
      ) : null}
    </div>
  )
}

function AllChangesRow({ selected, t, version }: { selected: boolean; t: TFunction<"jobs">; version: DiffReviewVersion }) {
  return (
    <span className="flex min-w-0 flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
      <span className="truncate">{t("review_version_all_changes")}</span>
      <span className="flex flex-wrap items-center gap-2 text-xs font-normal text-gray-500 dark:text-gray-400">
        <EndpointChip highlighted={selected} label={endpointShortLabel(version.base_ref, version.base_sha)} title={endpointTitle(version.base_ref, version.base_sha)} type={t("review_version_from_chip")} />
        <EndpointChip highlighted={selected} label={endpointShortLabel(version.head_ref, version.head_sha)} title={endpointTitle(version.head_ref, version.head_sha)} type={t("review_version_to_chip")} />
        <span>{filesLabel(t, version.files_count)}</span>
        <span>{commentsLabel(t, version.comments_count)}</span>
      </span>
    </span>
  )
}

function compareVersions(a: DiffReviewVersion, b: DiffReviewVersion) {
  if (isAllChangesVersion(a) && !isAllChangesVersion(b)) return -1
  if (!isAllChangesVersion(a) && isAllChangesVersion(b)) return 1
  return b.version_index - a.version_index || b.id - a.id
}

function RangeRow({ selected, t, version }: { selected: boolean; t: TFunction<"jobs">; version: DiffReviewVersion }) {
  return (
    <span className="grid min-w-0 gap-2 sm:grid-cols-[auto_auto_minmax(0,1fr)] sm:items-center">
      <span className="flex min-w-0 flex-wrap gap-2">
        <EndpointChip highlighted={selected} label={endpointShortLabel(version.base_ref, version.base_sha)} title={endpointTitle(version.base_ref, version.base_sha)} type={t("review_version_from_chip")} />
        <EndpointChip highlighted={selected} label={endpointShortLabel(version.head_ref, version.head_sha)} title={endpointTitle(version.head_ref, version.head_sha)} type={t("review_version_to_chip")} />
      </span>
      <span className="min-w-0 truncate font-medium">{rangeName(version)}</span>
      <span className="min-w-0 truncate text-xs text-gray-500 dark:text-gray-400">{metadataSummary(t, version)}</span>
    </span>
  )
}

function EndpointChip({ highlighted, label, title, type }: { highlighted: boolean; label: string; title: string; type: string }) {
  return (
    <span
      className={`inline-flex max-w-[9rem] shrink-0 items-center gap-1 rounded border px-2 py-0.5 text-xs ${highlighted ? "border-brand bg-brand text-white" : "border-gray-300 bg-white text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"}`}
      title={title}
    >
      <span className="font-semibold uppercase">{type}</span>
      <span className="truncate font-mono">{label}</span>
    </span>
  )
}

function collapsedLabel(t: TFunction<"jobs">, version: DiffReviewVersion) {
  if (isAllChangesVersion(version)) return t("review_version_all_changes")
  if (version.label) return version.label
  if (version.run_id) return `RUN-${version.run_id}`
  return t("review_version_prefix", { version: version.version_index })
}

function rangeName(version: DiffReviewVersion) {
  return version.run_id ? `RUN-${version.run_id}` : (version.label || version.reason || version.trigger_kind || `v${version.version_index}`)
}

function metadataSummary(t: TFunction<"jobs">, version: DiffReviewVersion) {
  return [
    t("review_version_prefix", { version: version.version_index }),
    version.workflow_id ? `WF-${version.workflow_id}` : null,
    version.run_id ? `RUN-${version.run_id}` : null,
    version.created_at ? relativeDate(version.created_at) : null,
    filesLabel(t, version.files_count),
    commentsLabel(t, version.comments_count)
  ].filter(Boolean).join(t("review_version_separator"))
}

function versionMetadata(t: TFunction<"jobs">, version: DiffReviewVersion, latest: boolean) {
  const created = version.created_at ? `${relativeDate(version.created_at)} (${absoluteDate(version.created_at)})` : t("review_version_time_unknown")
  const trigger = version.trigger_kind || version.reason || t("review_version_unknown_trigger")
  const workflow = version.workflow_id ? t("review_version_workflow", { id: version.workflow_id }) : t("review_version_no_workflow")
  const run = version.run_id ? t("review_version_run", { id: version.run_id }) : t("review_version_no_run")
  const comments = commentsLabel(t, version.comments_count)
  const range = t("review_version_range", { base: endpointLabel(version.base_ref, version.base_sha), head: endpointLabel(version.head_ref, version.head_sha) })
  if (isAllChangesVersion(version)) {
    return [
      t("review_version_all_changes"),
      range,
      filesLabel(t, version.files_count),
      comments
    ].join(t("review_version_separator"))
  }

  return [
    latest ? t("review_version_latest") : t("review_version_historical"),
    trigger,
    `${workflow}, ${run}`,
    created,
    range,
    filesLabel(t, version.files_count),
    comments
  ].join(t("review_version_separator"))
}

function optionAccessibleName(t: TFunction<"jobs">, version: DiffReviewVersion) {
  return [
    collapsedLabel(t, version),
    t("review_version_range", { base: endpointLabel(version.base_ref, version.base_sha), head: endpointLabel(version.head_ref, version.head_sha) }),
    metadataSummary(t, version)
  ].filter(Boolean).join(t("review_version_separator"))
}

function filesLabel(t: TFunction<"jobs">, count: number) {
  return t("review_version_files", { count })
}

function commentsLabel(t: TFunction<"jobs">, count: number) {
  return count > 0 ? t("review_version_comments", { count }) : t("review_version_no_comments")
}

function isAllChangesVersion(version: DiffReviewVersion) {
  return version.reason === "source_diff" || version.metadata?.range_kind === "all_changes"
}

function endpointLabel(ref: string | null | undefined, sha: string | null | undefined) {
  const primary = ref || shortSha(sha)
  return `${primary} (${shortSha(sha)})`
}

function shortSha(sha: string | null | undefined) {
  return sha ? sha.slice(0, 7) : "unknown"
}

function endpointShortLabel(ref: string | null | undefined, sha: string | null | undefined) {
  return truncateMiddle(ref || shortSha(sha), 18)
}

function endpointTitle(ref: string | null | undefined, sha: string | null | undefined) {
  return [ref, sha].filter(Boolean).join(" @ ") || "unknown"
}

function truncateMiddle(value: string, maxLength: number) {
  if (value.length <= maxLength) return value
  const keep = Math.floor((maxLength - 1) / 2)
  return `${value.slice(0, keep)}...${value.slice(value.length - keep)}`
}

function absoluteDate(value: string) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(value))
}

function relativeDate(value: string) {
  const then = new Date(value).getTime()
  const now = Date.now()
  const seconds = Math.round((then - now) / 1000)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60]
  ]
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  for (const [unit, unitSeconds] of units) {
    if (Math.abs(seconds) >= unitSeconds) return formatter.format(Math.round(seconds / unitSeconds), unit)
  }
  return formatter.format(seconds, "second")
}
