import type { GitHistoryBundleRef, GitHistoryCommit, GitHistoryEpicRef, GitHistoryJobRef } from "../api/gitHistory"

export type JobCommitGroup = {
  kind: "job"
  job: GitHistoryJobRef
  commits: GitHistoryCommit[]
}

export type EpicCommitGroup = {
  kind: "epic"
  epic: GitHistoryEpicRef
  commits: GitHistoryCommit[]
  jobGroups: JobCommitGroup[]
}

// The bundle-backed (non-Epic) mirror of EpicCommitGroup -- anchored by
// `bundle_landed`/`bundle_reconciliation` commits instead of `epic_landed`/
// `epic_reconciliation`, since a job bundle has a MergeTrain id but no Epic.
export type BundleCommitGroup = {
  kind: "bundle"
  bundle: GitHistoryBundleRef
  commits: GitHistoryCommit[]
  jobGroups: JobCommitGroup[]
}

export type StandaloneCommitGroup = {
  kind: "commit"
  commit: GitHistoryCommit
}

export type CommitGroup = EpicCommitGroup | BundleCommitGroup | JobCommitGroup | StandaloneCommitGroup

// Groups a flat, newest-first commit list into the nested shape the Git
// History tab renders: an Epic's `epic_landed` commit(s) anchor a group that
// nests every member Job's own `syrus_landed` commits underneath it, plus
// any `epic_reconciliation` commits (which belong to the Epic, not any
// single Job). A `syrus_landed` commit for a Job with no epic-landing
// anchor in view forms its own standalone Job group. Everything else
// (`external_pr`, `external_push`) stays an individual, ungrouped entry.
//
// Safe to call on the full accumulated commit list on every render (e.g.
// after "load more") -- groups are rebuilt from scratch each time, so a
// group split across a pagination boundary reassembles automatically once
// the rest of its commits load, regardless of where the boundary fell.
export function groupCommits(commits: GitHistoryCommit[]): CommitGroup[] {
  const topLevel: CommitGroup[] = []
  const epicGroups = new Map<number, EpicCommitGroup>()
  const bundleGroups = new Map<number, BundleCommitGroup>()
  const jobGroups = new Map<number, JobCommitGroup>()

  const epicGroupFor = (epic: GitHistoryEpicRef): EpicCommitGroup => {
    const existing = epicGroups.get(epic.id)
    if (existing) return existing

    const group: EpicCommitGroup = { kind: "epic", epic, commits: [], jobGroups: [] }
    epicGroups.set(epic.id, group)
    topLevel.push(group)
    return group
  }

  const bundleGroupFor = (bundle: GitHistoryBundleRef): BundleCommitGroup => {
    const existing = bundleGroups.get(bundle.id)
    if (existing) return existing

    const group: BundleCommitGroup = { kind: "bundle", bundle, commits: [], jobGroups: [] }
    bundleGroups.set(bundle.id, group)
    topLevel.push(group)
    return group
  }

  const jobGroupFor = (job: GitHistoryJobRef, parentGroup?: EpicCommitGroup | BundleCommitGroup): JobCommitGroup => {
    const existing = jobGroups.get(job.id)
    if (existing) return existing

    const group: JobCommitGroup = { kind: "job", job, commits: [] }
    jobGroups.set(job.id, group)
    if (parentGroup) {
      parentGroup.jobGroups.push(group)
    } else {
      topLevel.push(group)
    }
    return group
  }

  for (const commit of commits) {
    if (commit.classification === "epic_landed" && commit.epic) {
      const epicGroup = epicGroupFor(commit.epic)
      epicGroup.commits.push(commit)
      for (const job of commit.jobs ?? []) jobGroupFor(job, epicGroup)
    } else if (commit.classification === "epic_reconciliation" && commit.epic) {
      epicGroupFor(commit.epic).commits.push(commit)
    } else if (commit.classification === "bundle_landed" && commit.bundle) {
      const bundleGroup = bundleGroupFor(commit.bundle)
      bundleGroup.commits.push(commit)
      for (const job of commit.jobs ?? []) jobGroupFor(job, bundleGroup)
    } else if (commit.classification === "bundle_reconciliation" && commit.bundle) {
      bundleGroupFor(commit.bundle).commits.push(commit)
    } else if (commit.classification === "syrus_landed" && commit.job) {
      jobGroupFor(commit.job).commits.push(commit)
    } else {
      topLevel.push({ kind: "commit", commit })
    }
  }

  return topLevel
}

export function commitGroupKey(group: CommitGroup): string {
  if (group.kind === "epic") return `epic-${group.epic.id}`
  if (group.kind === "bundle") return `bundle-${group.bundle.id}`
  if (group.kind === "job") return `job-${group.job.id}`
  return `commit-${group.commit.sha}`
}
