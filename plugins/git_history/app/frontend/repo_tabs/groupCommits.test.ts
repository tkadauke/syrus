import { describe, expect, it } from "vitest"
import type { GitHistoryCommit } from "../api/gitHistory"
import { commitGroupKey, groupCommits } from "./groupCommits"

function commit(overrides: Partial<GitHistoryCommit> & Pick<GitHistoryCommit, "sha" | "classification">): GitHistoryCommit {
  return {
    short_sha: overrides.sha.slice(0, 10),
    subject: "a commit",
    authored_at: "2026-08-20T10:00:00Z",
    ...overrides
  }
}

describe("groupCommits", () => {
  it("nests an epic_landed commit's member jobs, and each job's own implementation commits, under the epic group", () => {
    const epic = { id: 9, slug: "EPIC-9", title: "Theming" }
    const job42 = { id: 42, slug: "JOB-42", title: "Add dark mode toggle" }
    const job43 = { id: 43, slug: "JOB-43", title: "Add light mode toggle" }

    const commits = [
      commit({
        sha: "1".repeat(40),
        subject: "Merge Epic #9 via Syrus merge-train",
        classification: "epic_landed",
        epic,
        jobs: [job42, job43]
      }),
      // Ancestor implementation commits appear later in the (newest-first) log.
      commit({ sha: "2".repeat(40), subject: "Implement dark mode", classification: "syrus_landed", job: job42, epic, user: { id: 1, display_name: "Ada" } }),
      commit({ sha: "3".repeat(40), subject: "Autofix formatting", classification: "syrus_landed", job: job42, epic, user: { id: 1, display_name: "Ada" } }),
      commit({ sha: "4".repeat(40), subject: "Implement light mode", classification: "syrus_landed", job: job43, epic, user: { id: 2, display_name: "Grace" } })
    ]

    const groups = groupCommits(commits)

    expect(groups).toHaveLength(1)
    const [epicGroup] = groups
    if (epicGroup.kind !== "epic") throw new Error("expected an epic group")

    expect(epicGroup.epic).toEqual(epic)
    expect(epicGroup.commits.map((c) => c.sha)).toEqual([commits[0].sha])
    expect(epicGroup.jobGroups).toHaveLength(2)

    const [job42Group, job43Group] = epicGroup.jobGroups
    expect(job42Group.job).toEqual(job42)
    expect(job42Group.commits.map((c) => c.sha)).toEqual([commits[1].sha, commits[2].sha])
    expect(job43Group.job).toEqual(job43)
    expect(job43Group.commits.map((c) => c.sha)).toEqual([commits[3].sha])
  })

  it("attaches an epic_reconciliation commit to its epic group and not to any job", () => {
    const epic = { id: 9, slug: "EPIC-9", title: "Theming" }
    const job42 = { id: 42, slug: "JOB-42", title: "Add dark mode toggle" }

    const commits = [
      commit({ sha: "1".repeat(40), classification: "epic_landed", epic, jobs: [job42] }),
      commit({ sha: "2".repeat(40), subject: "Syrus merge-train reconciliation", classification: "epic_reconciliation", epic }),
      commit({ sha: "3".repeat(40), classification: "syrus_landed", job: job42, epic })
    ]

    const groups = groupCommits(commits)
    expect(groups).toHaveLength(1)
    const [epicGroup] = groups
    if (epicGroup.kind !== "epic") throw new Error("expected an epic group")

    expect(epicGroup.commits.map((c) => c.sha)).toEqual([commits[0].sha, commits[1].sha])
    expect(epicGroup.jobGroups).toHaveLength(1)
    expect(epicGroup.jobGroups[0].commits.map((c) => c.sha)).toEqual([commits[2].sha])
    // The reconciliation commit must not have ended up inside the job's own commits.
    expect(epicGroup.jobGroups[0].commits.some((c) => c.classification === "epic_reconciliation")).toBe(false)
  })

  it("groups a job's own syrus_landed commits together as a standalone group when no epic_landed commit is in view", () => {
    const job = { id: 55, slug: "JOB-55", title: "Ship it quietly" }

    const commits = [
      commit({ sha: "1".repeat(40), subject: "Autofix lint", classification: "syrus_landed", job, epic: null }),
      commit({ sha: "2".repeat(40), subject: "Ship it quietly", classification: "syrus_landed", job, epic: null })
    ]

    const groups = groupCommits(commits)
    expect(groups).toHaveLength(1)
    const [jobGroup] = groups
    if (jobGroup.kind !== "job") throw new Error("expected a job group")

    expect(jobGroup.job).toEqual(job)
    expect(jobGroup.commits.map((c) => c.sha)).toEqual([commits[0].sha, commits[1].sha])
  })

  it("groups a legacy-fallback syrus_landed commit identically to a normal one -- the wire shape carries no legacy marker", () => {
    const job = { id: 55, slug: "JOB-55", title: "Ship it quietly" }
    const legacyLookingCommit = commit({ sha: "1".repeat(40), classification: "syrus_landed", job, epic: null, user: { id: 4, display_name: "Owner" } })

    const groups = groupCommits([legacyLookingCommit])
    expect(groups).toHaveLength(1)
    expect(groups[0]).toEqual({ kind: "job", job, commits: [legacyLookingCommit] })
  })

  it("leaves external_pr and external_push commits as individual, ungrouped entries", () => {
    const commits = [
      commit({ sha: "1".repeat(40), classification: "external_pr", job: { id: 100, slug: "JOB-100", title: null }, pr_number: 55 }),
      commit({ sha: "2".repeat(40), classification: "external_push", author: { name: "Grace Hopper", email: null } })
    ]

    const groups = groupCommits(commits)
    expect(groups).toEqual([
      { kind: "commit", commit: commits[0] },
      { kind: "commit", commit: commits[1] }
    ])
  })
})

describe("commitGroupKey", () => {
  it("returns a stable, type-prefixed key for each group kind", () => {
    expect(commitGroupKey({ kind: "epic", epic: { id: 9, slug: "EPIC-9", title: null }, commits: [], jobGroups: [] })).toBe("epic-9")
    expect(commitGroupKey({ kind: "job", job: { id: 42, slug: "JOB-42", title: null }, commits: [] })).toBe("job-42")
    expect(commitGroupKey({ kind: "commit", commit: commit({ sha: "a".repeat(40), classification: "external_push" }) })).toBe(`commit-${"a".repeat(40)}`)
  })
})
