// Workflow branch-divergence types + parsers extracted from JobDetail.tsx.
//
// Defensively read the branch_divergence / recovery artifacts off a workflow
// into typed shapes the divergence banner renders. Pure over the job workflow
// type; lifting the types here lets the divergence banner component move out
// of the 3k-line JobDetail.tsx.
import type { JobWorkflow } from "../../api/jobs"

export type BranchDivergence = {
  branch: string
  remote_sha: string | null
  local_sha: string | null
  detected_at: string | null
  message: string | null
  comparison: BranchDivergenceComparison | null
  recovery_pending: BranchDivergenceRecoveryStatus | null
  recovery_error: BranchDivergenceRecoveryStatus | null
}
export type BranchDivergenceCommit = {
  sha: string
  author: string | null
  date: string | null
  subject: string | null
}
export type BranchDivergenceCommitList = {
  commits: BranchDivergenceCommit[]
  truncated: boolean
}
export type BranchDivergenceComparison = {
  discarded: BranchDivergenceCommitList | null
  published: BranchDivergenceCommitList | null
  discardedFiles: { files: string[]; truncated: boolean } | null
}
export type BranchDivergenceRecoveryStatus = {
  message?: string
  action?: string
  at?: string
}

export function workflowBranchDivergence(workflow: JobWorkflow): BranchDivergence | null {
  const artifacts = workflow.artifacts || {}
  if (artifacts.branch_divergence_recovery) return null
  const raw = artifacts.branch_divergence
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  return {
    branch: typeof row.branch === "string" ? row.branch : "",
    remote_sha: typeof row.remote_sha === "string" ? row.remote_sha : null,
    local_sha: typeof row.local_sha === "string" ? row.local_sha : null,
    detected_at: typeof row.detected_at === "string" ? row.detected_at : null,
    message: typeof row.message === "string" ? row.message : null,
    comparison: parseComparison(row.comparison),
    recovery_pending: workflowBranchRecoveryStatus(artifacts.branch_divergence_recovery_pending),
    recovery_error: workflowBranchRecoveryStatus(artifacts.branch_divergence_recovery_error)
  }
}

export function workflowBranchRecoveryStatus(raw: unknown): BranchDivergenceRecoveryStatus | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  const status: BranchDivergenceRecoveryStatus = {}
  if (typeof row.message === "string") status.message = row.message
  if (typeof row.action === "string") status.action = row.action
  if (typeof row.at === "string") status.at = row.at
  return Object.keys(status).length > 0 ? status : null
}

function parseComparison(raw: unknown): BranchDivergenceComparison | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  const comparison: BranchDivergenceComparison = {
    discarded: parseCommitList(row.discarded),
    published: parseCommitList(row.published),
    discardedFiles: parseFileList(row.discarded_files)
  }
  if (!comparison.discarded && !comparison.published && !comparison.discardedFiles) return null
  return comparison
}

function parseCommitList(raw: unknown): BranchDivergenceCommitList | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  const commits = Array.isArray(row.commits)
    ? row.commits.flatMap((entry) => {
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) return []
        const commit = entry as Record<string, unknown>
        if (typeof commit.sha !== "string" || commit.sha.length === 0) return []
        return [
          {
            sha: commit.sha,
            author: typeof commit.author === "string" ? commit.author : null,
            date: typeof commit.date === "string" ? commit.date : null,
            subject: typeof commit.subject === "string" ? commit.subject : null
          }
        ]
      })
    : []
  if (commits.length === 0) return null
  return { commits, truncated: row.truncated === true }
}

function parseFileList(raw: unknown): { files: string[]; truncated: boolean } | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null

  const row = raw as Record<string, unknown>
  const files = Array.isArray(row.files) ? row.files.filter((f): f is string => typeof f === "string") : []
  if (files.length === 0) return null
  return { files, truncated: row.truncated === true }
}
