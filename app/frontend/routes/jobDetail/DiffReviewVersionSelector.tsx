import { Select } from "../../components/Select"
import { useT } from "../../hooks/useT"
import type { DiffReviewVersion } from "../../api/jobs"
import type { TFunction } from "i18next"

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
  const ordered = [...versions].sort((a, b) => b.version_index - a.version_index || b.id - a.id)
  const selected = ordered.find((version) => version.id === selectedVersionId) || ordered[0] || null

  if (ordered.length === 0) {
    return (
      <div className="rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-500 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
        {t("review_versions_empty")}
      </div>
    )
  }

  return (
    <div className="w-full min-w-0 max-w-full space-y-1 sm:max-w-xl">
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="diff-review-version-select">
        {t("review_version_label")}
      </label>
      <Select
        disabled={disabled || ordered.length <= 1}
        className="max-w-full truncate"
        fullWidth
        id="diff-review-version-select"
        onChange={(event) => onChange(Number(event.target.value))}
        value={selected?.id || ""}
      >
        {ordered.map((version) => (
          <option key={version.id} value={version.id}>
            {versionOptionLabel(t, version, version.id === latestVersionId)}
          </option>
        ))}
      </Select>
      {selected ? (
        <p className="max-w-3xl break-words text-xs text-gray-500 dark:text-gray-400">
          {versionMetadata(t, selected, selected.id === latestVersionId)}
        </p>
      ) : null}
    </div>
  )
}

export function versionOptionLabel(t: TFunction<"jobs">, version: DiffReviewVersion, latest: boolean) {
  const pieces = [
    isAllChangesVersion(version) ? t("review_version_all_changes") : (latest ? t("review_version_latest_prefix", { version: version.version_index }) : t("review_version_prefix", { version: version.version_index })),
    isAllChangesVersion(version) ? null : (version.label || version.reason || version.trigger_kind || t("review_version_default_reason")),
    version.workflow_id ? `WF-${version.workflow_id}` : null,
    version.run_id ? `RUN-${version.run_id}` : null,
    version.created_at ? absoluteDate(version.created_at) : null,
    t("review_version_range", { base: endpointLabel(version.base_ref, version.base_sha), head: endpointLabel(version.head_ref, version.head_sha) }),
    version.comments_count > 0 ? t("review_version_comments", { count: version.comments_count }) : t("review_version_no_comments")
  ].filter(Boolean)
  return pieces.join(t("review_version_separator"))
}

function versionMetadata(t: TFunction<"jobs">, version: DiffReviewVersion, latest: boolean) {
  const created = version.created_at ? `${relativeDate(version.created_at)} (${absoluteDate(version.created_at)})` : t("review_version_time_unknown")
  const trigger = version.trigger_kind || version.reason || t("review_version_unknown_trigger")
  const workflow = version.workflow_id ? t("review_version_workflow", { id: version.workflow_id }) : t("review_version_no_workflow")
  const run = version.run_id ? t("review_version_run", { id: version.run_id }) : t("review_version_no_run")
  const comments = t("review_version_comments", { count: version.comments_count })
  const range = t("review_version_range", { base: endpointLabel(version.base_ref, version.base_sha), head: endpointLabel(version.head_ref, version.head_sha) })
  if (isAllChangesVersion(version)) {
    return [
      t("review_version_all_changes"),
      range,
      comments
    ].join(t("review_version_separator"))
  }

  return [
    latest ? t("review_version_latest") : t("review_version_historical"),
    trigger,
    `${workflow}, ${run}`,
    created,
    range,
    comments
  ].join(t("review_version_separator"))
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
