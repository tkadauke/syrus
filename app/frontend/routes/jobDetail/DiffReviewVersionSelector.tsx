import { Select } from "../../components/Select"
import type { DiffReviewVersion } from "../../api/jobs"

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
  const ordered = [...versions].sort((a, b) => b.version_index - a.version_index || b.id - a.id)
  const selected = ordered.find((version) => version.id === selectedVersionId) || ordered[0] || null

  if (ordered.length === 0) {
    return (
      <div className="rounded border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-500 dark:border-gray-800 dark:bg-gray-950 dark:text-gray-400">
        No diff versions yet.
      </div>
    )
  }

  return (
    <div className="min-w-0 space-y-1">
      <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="diff-review-version-select">
        Diff version
      </label>
      <Select
        disabled={disabled || ordered.length <= 1}
        fullWidth={false}
        id="diff-review-version-select"
        onChange={(event) => onChange(Number(event.target.value))}
        value={selected?.id || ""}
      >
        {ordered.map((version) => (
          <option key={version.id} value={version.id}>
            {versionOptionLabel(version, version.id === latestVersionId)}
          </option>
        ))}
      </Select>
      {selected ? (
        <p className="max-w-3xl break-words text-xs text-gray-500 dark:text-gray-400">
          {versionMetadata(selected, selected.id === latestVersionId)}
        </p>
      ) : null}
    </div>
  )
}

export function versionOptionLabel(version: DiffReviewVersion, latest: boolean) {
  const pieces = [
    `v${version.version_index}${latest ? " latest" : ""}`,
    version.label || version.reason || version.trigger_kind || "Diff review",
    version.workflow_id ? `WF-${version.workflow_id}` : null,
    version.run_id ? `RUN-${version.run_id}` : null,
    version.created_at ? absoluteDate(version.created_at) : null,
    `${shortSha(version.base_sha)}..${shortSha(version.head_sha)}`,
    version.comments_count > 0 ? `${version.comments_count} ${version.comments_count === 1 ? "comment" : "comments"}` : "no comments"
  ].filter(Boolean)
  return pieces.join(" - ")
}

function versionMetadata(version: DiffReviewVersion, latest: boolean) {
  const created = version.created_at ? `${relativeDate(version.created_at)} (${absoluteDate(version.created_at)})` : "time unknown"
  const trigger = version.trigger_kind || version.reason || "unknown trigger"
  const workflow = version.workflow_id ? `Workflow ${version.workflow_id}` : "no workflow"
  const run = version.run_id ? `Run ${version.run_id}` : "no run"
  const comments = version.comments_count === 1 ? "1 comment" : `${version.comments_count} comments`
  return `${latest ? "Latest" : "Historical"} - ${trigger} - ${workflow}, ${run} - ${created} - ${shortSha(version.base_sha)}..${shortSha(version.head_sha)} - ${comments}`
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
