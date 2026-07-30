// Workflow artifact/timestamp helpers extracted from JobDetail.tsx.
//
// latestTypedArtifacts finds the most-recent workflow that stored any
// typed_artifacts entries and returns them (enriched with renderer_type by
// the backend). If multiple workflows have entries, the newest wins.
//
// Find the most recent workflow that recorded a coverage artifact, and the
// parsed created-at time for ordering. Pure over the job workflow + coverage
// types; lifted out of the 3k-line JobDetail.tsx.
import type { CoverageArtifact, JobWorkflow, TypedArtifact } from "../../api/jobs"

export function latestWorkflowCoverage(workflows: JobWorkflow[]): { workflowId: number; coverage: CoverageArtifact } | null {
  for (let i = workflows.length - 1; i >= 0; i--) {
    const artifacts = workflows[i].artifacts
    const cov = artifacts?.["coverage"] as CoverageArtifact | undefined
    if (cov) return { workflowId: workflows[i].id, coverage: cov }
  }
  return null
}

export function workflowCreatedAtTime(workflow: JobWorkflow) {
  if (!workflow.created_at) return 0
  const time = Date.parse(workflow.created_at)
  return Number.isNaN(time) ? 0 : time
}

export function latestTypedArtifacts(workflows: JobWorkflow[]): TypedArtifact[] | null {
  for (let i = workflows.length - 1; i >= 0; i--) {
    const raw = workflows[i].artifacts?.["typed_artifacts"]
    if (Array.isArray(raw) && raw.length > 0) return raw as TypedArtifact[]
  }
  return null
}
