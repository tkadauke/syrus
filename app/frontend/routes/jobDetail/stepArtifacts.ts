// Step artifact parsers extracted from JobDetail.tsx.
//
// Defensively parse the raw test-plan and adversarial-review step artifacts
// (untyped JSON bags) into the typed shapes the panels render. Pure over the
// job API types; lifted out of the 3k-line JobDetail.tsx.
import type { JobAdversarialReviewIteration, JobVisualReviewArtifact, JobVisualReviewIteration } from "../../api/jobs"

export function stepArtifactTestPlan(raw: unknown): { steps: string[]; notes: string | null } | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  const obj = raw as Record<string, unknown>
  const steps = Array.isArray(obj.steps) ? obj.steps.filter((s): s is string => typeof s === "string") : []
  if (steps.length === 0 && !obj.notes) return null
  return { steps, notes: typeof obj.notes === "string" ? obj.notes : null }
}

export function stepArtifactAdversarialReview(raw: unknown): JobAdversarialReviewIteration[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null
  const result: JobAdversarialReviewIteration[] = []
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue
    const obj = item as Record<string, unknown>
    if (typeof obj.iteration === "number" && typeof obj.critique === "string" && (obj.verdict === "approved" || obj.verdict === "needs_work")) {
      result.push({ iteration: obj.iteration, critique: obj.critique, verdict: obj.verdict })
    }
  }
  return result.length > 0 ? result : null
}

export function stepArtifactVisualReview(raw: unknown): JobVisualReviewIteration[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null
  const result: JobVisualReviewIteration[] = []
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue
    const obj = item as Record<string, unknown>
    if (typeof obj.iteration !== "number") continue
    if (typeof obj.critique !== "string") continue
    if (obj.verdict !== "approved" && obj.verdict !== "needs_work" && obj.verdict !== "skipped") continue

    const artifacts = Array.isArray(obj.artifacts) ? obj.artifacts.flatMap(parseVisualReviewArtifact) : []
    result.push({ iteration: obj.iteration, critique: obj.critique, verdict: obj.verdict, artifacts })
  }
  return result.length > 0 ? result : null
}

function parseVisualReviewArtifact(raw: unknown): JobVisualReviewArtifact[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return []
  const obj = raw as Record<string, unknown>
  if (typeof obj.type !== "string") return []
  return [{
    type: obj.type,
    title: typeof obj.title === "string" ? obj.title : null,
    image_url: typeof obj.image_url === "string" ? obj.image_url : null,
    content_type: typeof obj.content_type === "string" ? obj.content_type : null,
    byte_size: typeof obj.byte_size === "number" ? obj.byte_size : null,
    created_at: typeof obj.created_at === "string" ? obj.created_at : null
  }]
}
