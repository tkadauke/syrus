export type JobItemForGrouping = {
  id: number
  epic_id: number | null
  epic_title?: string | null
  branch_name?: string | null
}

export type InboxEntry<T extends JobItemForGrouping = JobItemForGrouping> =
  | { kind: 'epic'; epicId: number; epicTitle: string; jobs: T[] }
  | { kind: 'job'; job: T }

export function groupJobsByEpic<T extends JobItemForGrouping>(jobs: T[]): InboxEntry<T>[] {
  const entries: InboxEntry<T>[] = []
  const epicEntries = new Map<number, { kind: 'epic'; epicId: number; epicTitle: string; jobs: T[] }>()

  for (const job of jobs) {
    if (job.epic_id == null) {
      entries.push({ kind: 'job', job })
    } else {
      const epicId = job.epic_id
      const existing = epicEntries.get(epicId)
      if (existing) {
        existing.jobs.push(job)
      } else {
        const entry = { kind: 'epic' as const, epicId, epicTitle: job.epic_title ?? 'Epic', jobs: [job] }
        epicEntries.set(epicId, entry)
        entries.push(entry)
      }
    }
  }

  return entries
}

export function epicFullyImplemented(jobs: JobItemForGrouping[]): boolean {
  return jobs.length > 0 && jobs.every(j => Boolean(j.branch_name?.trim()))
}
