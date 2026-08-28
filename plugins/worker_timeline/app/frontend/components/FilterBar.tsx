import { useT } from "@app/hooks/useT"
import type { WorkerTimelineFiltersPayload } from "../api/workerTimeline"

export type WorkerTimelineFilterValue = {
  repositoryId: string
  epicId: string
  hostname: string
  statuses: string[]
  from: string
  to: string
}

const ALL_STATUSES = [ "queued", "running", "succeeded", "failed", "cancelled" ]

export function FilterBar({
  value,
  options,
  onChange
}: {
  value: WorkerTimelineFilterValue
  options: WorkerTimelineFiltersPayload | undefined
  onChange: (next: WorkerTimelineFilterValue) => void
}) {
  const { t } = useT("worker_timeline")

  function toggleStatus(status: string) {
    const next = value.statuses.includes(status)
      ? value.statuses.filter((candidate) => candidate !== status)
      : [ ...value.statuses, status ]
    onChange({ ...value, statuses: next })
  }

  return (
    <section aria-label={t("filters_aria")} className="flex flex-wrap items-end gap-3 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-3">
      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("filter_repository")}
        <select
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => onChange({ ...value, repositoryId: event.target.value })}
          value={value.repositoryId}
        >
          <option value="">{t("filter_all_repositories")}</option>
          {(options?.repositories ?? []).map((repository) => (
            <option key={repository.id} value={repository.id}>{repository.slug}</option>
          ))}
        </select>
      </label>

      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("filter_epic")}
        <select
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => onChange({ ...value, epicId: event.target.value })}
          value={value.epicId}
        >
          <option value="">{t("filter_all_epics")}</option>
          {(options?.epics ?? []).map((epic) => (
            <option key={epic.id} value={epic.id}>{epic.display_number} · {epic.title}</option>
          ))}
        </select>
      </label>

      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("filter_hostname")}
        <select
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => onChange({ ...value, hostname: event.target.value })}
          value={value.hostname}
        >
          <option value="">{t("filter_all_hostnames")}</option>
          {(options?.hostnames ?? []).map((hostname) => (
            <option key={hostname} value={hostname}>{hostname}</option>
          ))}
        </select>
      </label>

      <fieldset className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        <legend>{t("filter_status")}</legend>
        <div className="flex flex-wrap gap-2">
          {(options?.statuses ?? ALL_STATUSES).map((status) => (
            <label className="inline-flex items-center gap-1 rounded border border-gray-300 dark:border-gray-600 px-2 py-1 text-xs normal-case text-gray-700 dark:text-gray-300" key={status}>
              <input
                checked={value.statuses.includes(status)}
                onChange={() => toggleStatus(status)}
                type="checkbox"
              />
              {status}
            </label>
          ))}
        </div>
      </fieldset>

      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("filter_from")}
        <input
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => onChange({ ...value, from: event.target.value })}
          type="datetime-local"
          value={value.from}
        />
      </label>

      <label className="grid gap-1 text-xs font-medium text-gray-600 dark:text-gray-400">
        {t("filter_to")}
        <input
          className="rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1.5 text-sm text-gray-900 dark:text-gray-100"
          onChange={(event) => onChange({ ...value, to: event.target.value })}
          type="datetime-local"
          value={value.to}
        />
      </label>
    </section>
  )
}
