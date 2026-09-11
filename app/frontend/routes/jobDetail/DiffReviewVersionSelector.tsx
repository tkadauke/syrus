import { useEffect, useId, useMemo, useRef, useState } from "react"
import { useT } from "../../hooks/useT"
import type { DiffReviewVersion } from "../../api/jobs"
import type { TFunction } from "i18next"
import type { KeyboardEvent, MouseEventHandler } from "react"

export type DiffReviewRangeSelection = {
  baseSha: string
  headSha: string
  versionId: number | null
}

export function DiffReviewVersionSelector({
  disabled = false,
  latestVersionId,
  onChange,
  onRangeChange,
  selectedRange,
  selectedVersionId,
  versions
}: {
  disabled?: boolean
  latestVersionId: number | null
  onChange: (versionId: number) => void
  onRangeChange?: (range: DiffReviewRangeSelection) => void
  selectedRange?: { baseSha: string; headSha: string } | null
  selectedVersionId: number | null
  versions: DiffReviewVersion[]
}) {
  const { t } = useT("jobs")
  const listboxId = useId()
  const buttonRef = useRef<HTMLButtonElement | null>(null)
  const optionRefs = useRef<Array<HTMLDivElement | null>>([])
  const [open, setOpen] = useState(false)
  const ordered = useMemo(() => [...versions].sort(compareVersions), [versions])
  const selected = ordered.find((version) => version.id === selectedVersionId) || (selectedRange ? null : ordered[0]) || null
  const rangeBaseSha = selectedRange?.baseSha || selected?.base_sha || ordered[0]?.base_sha || ""
  const rangeHeadSha = selectedRange?.headSha || selected?.head_sha || ordered[ordered.length - 1]?.head_sha || ""
  const displayLabel = selectedRange ? selectedRangeLabel(t, ordered, rangeBaseSha, rangeHeadSha) : selected ? collapsedLabel(t, selected) : t("review_version_label")
  const selectedIndex = Math.max(0, ordered.findIndex((version) => version.id === selected?.id || version.base_sha === rangeBaseSha || version.head_sha === rangeHeadSha))
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

  function selectEndpoint(version: DiffReviewVersion, endpoint: "from" | "to") {
    const nextBaseSha = endpoint === "from" ? version.base_sha : rangeBaseSha
    const nextHeadSha = endpoint === "to" ? version.head_sha : rangeHeadSha
    const matchingVersion = findMatchingVersion(ordered, nextBaseSha, nextHeadSha)
    if (matchingVersion) {
      selectVersion(matchingVersion)
      return
    }

    setOpen(false)
    onRangeChange?.({ baseSha: nextBaseSha, headSha: nextHeadSha, versionId: null })
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

  function onOptionKeyDown(event: KeyboardEvent<HTMLDivElement>, version: DiffReviewVersion) {
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
        <span className="min-w-0 truncate">{displayLabel}</span>
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
            const selectedOption = version.id === selected?.id || (version.base_sha === rangeBaseSha && version.head_sha === rangeHeadSha)
            const fromSelected = version.base_sha === rangeBaseSha
            const toSelected = version.head_sha === rangeHeadSha
            const allChanges = isAllChangesVersion(version)
            return (
              <div
                aria-label={optionAccessibleName(t, version)}
                aria-selected={selectedOption}
                className={`block w-full rounded px-2.5 py-2 text-left text-sm focus:outline-none focus:ring-2 focus:ring-brand/40 ${selectedOption ? "bg-brand/10 text-brand dark:text-brand-emphasis" : "text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-900"} ${allChanges ? "border border-brand/30 bg-brand/5 font-medium" : ""}`}
                id={`${listboxId}-option-${version.id}`}
                key={version.id}
                onClick={allChanges ? () => selectVersion(version) : undefined}
                onKeyDown={(event) => onOptionKeyDown(event, version)}
                ref={(element) => { optionRefs.current[index] = element }}
                role="option"
                tabIndex={activeIndex === index ? 0 : -1}
              >
                {allChanges ? (
                  <AllChangesRow selected={selectedOption} t={t} version={version} />
                ) : (
                  <RangeRow
                    fromSelected={fromSelected}
                    onSelectEndpoint={(endpoint) => selectEndpoint(version, endpoint)}
                    onSelectVersion={() => selectVersion(version)}
                    selected={selectedOption}
                    t={t}
                    toSelected={toSelected}
                    version={version}
                  />
                )}
              </div>
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
    <span className="flex min-w-0 items-center justify-between">
      <span className="truncate">{t("review_version_all_changes")}</span>
      {selected ? <span aria-hidden="true" className="h-2 w-2 rounded-full bg-brand" /> : null}
    </span>
  )
}

function compareVersions(a: DiffReviewVersion, b: DiffReviewVersion) {
  if (isAllChangesVersion(a) && !isAllChangesVersion(b)) return -1
  if (!isAllChangesVersion(a) && isAllChangesVersion(b)) return 1
  return a.version_index - b.version_index || a.id - b.id
}

function RangeRow({
  fromSelected,
  onSelectEndpoint,
  onSelectVersion,
  selected,
  t,
  toSelected,
  version
}: {
  fromSelected: boolean
  onSelectEndpoint: (endpoint: "from" | "to") => void
  onSelectVersion: () => void
  selected: boolean
  t: TFunction<"jobs">
  toSelected: boolean
  version: DiffReviewVersion
}) {
  return (
    <span className="grid min-w-0 grid-cols-[auto_auto_minmax(0,1fr)] items-center gap-2">
      <span className="contents">
        <EndpointChip
          ariaLabel={`${t("review_version_from_chip")} ${compactVersionSummary(t, version)}`}
          highlighted={fromSelected || selected}
          label=""
          onClick={() => onSelectEndpoint("from")}
          title={endpointTitle(version.base_ref, version.base_sha)}
          type={t("review_version_from_chip")}
        />
        <EndpointChip
          ariaLabel={`${t("review_version_to_chip")} ${compactVersionSummary(t, version)}`}
          highlighted={toSelected || selected}
          label=""
          onClick={() => onSelectEndpoint("to")}
          title={endpointTitle(version.head_ref, version.head_sha)}
          type={t("review_version_to_chip")}
        />
      </span>
      <button
        className="min-w-0 truncate text-left font-medium hover:underline focus:outline-none focus:ring-2 focus:ring-brand/40"
        onClick={onSelectVersion}
        title={metadataTitle(t, version)}
        type="button"
      >
        {compactVersionSummary(t, version)}
      </button>
    </span>
  )
}

function EndpointChip({ ariaLabel, highlighted, label, onClick, title, type }: { ariaLabel?: string; highlighted: boolean; label: string; onClick?: MouseEventHandler<HTMLButtonElement>; title: string; type: string }) {
  const className = `inline-flex h-7 w-16 shrink-0 items-center justify-center gap-1 rounded border px-2 py-0.5 text-xs ${onClick ? "cursor-pointer hover:border-brand/70" : ""} ${highlighted ? "border-brand bg-brand text-white" : "border-gray-300 bg-white text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200"}`
  const content = (
    <>
      <span className="font-semibold uppercase">{type}</span>
      {label ? <span className="truncate font-mono">{label}</span> : null}
    </>
  )
  if (!onClick) {
    return (
      <span className={className} title={title}>
        {content}
      </span>
    )
  }

  return (
    <button aria-label={ariaLabel} className={className} onClick={onClick} title={title} type="button">
      {content}
    </button>
  )
}

function collapsedLabel(t: TFunction<"jobs">, version: DiffReviewVersion) {
  if (isAllChangesVersion(version)) return t("review_version_all_changes")
  if (version.label) return version.label
  if (version.run_id) return `RUN-${version.run_id}`
  return t("review_version_prefix", { version: version.version_index })
}

function selectedRangeLabel(t: TFunction<"jobs">, versions: DiffReviewVersion[], baseSha: string, headSha: string) {
  const matching = findMatchingVersion(versions, baseSha, headSha)
  if (matching) return collapsedLabel(t, matching)

  const fromVersion = versions.find((version) => version.base_sha === baseSha)
  const toVersion = versions.find((version) => version.head_sha === headSha)
  const from = fromVersion ? t("review_version_prefix", { version: fromVersion.version_index }) : shortSha(baseSha)
  const to = toVersion ? t("review_version_prefix", { version: toVersion.version_index }) : shortSha(headSha)
  return `${from} to ${to}`
}

function rangeName(version: DiffReviewVersion) {
  return version.run_id ? `RUN-${version.run_id}` : (version.label || version.reason || version.trigger_kind || `v${version.version_index}`)
}

function compactVersionSummary(t: TFunction<"jobs">, version: DiffReviewVersion) {
  return [t("review_version_prefix", { version: version.version_index }), rangeName(version)].filter(Boolean).join(" ")
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

function metadataTitle(t: TFunction<"jobs">, version: DiffReviewVersion) {
  return [
    metadataSummary(t, version),
    t("review_version_range", { base: endpointLabel(version.base_ref, version.base_sha), head: endpointLabel(version.head_ref, version.head_sha) })
  ].join(t("review_version_separator"))
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

function findMatchingVersion(versions: DiffReviewVersion[], baseSha: string, headSha: string) {
  return versions.find((version) => version.base_sha === baseSha && version.head_sha === headSha) || null
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

function endpointTitle(ref: string | null | undefined, sha: string | null | undefined) {
  return [ref, sha].filter(Boolean).join(" @ ") || "unknown"
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
