// Step artifact parsers extracted from JobDetail.tsx.
//
// Defensively parse the raw test-plan and adversarial-review step artifacts
// (untyped JSON bags) into the typed shapes the panels render. Pure over the
// job API types; lifted out of the 3k-line JobDetail.tsx.
import type { JobAdversarialReviewIteration, JobSecurityReviewIteration, JobVisualReviewArtifact, JobVisualReviewIteration } from "../../api/jobs"

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
  const entries = raw.filter(isRecord)
  for (const obj of entries) {
    if (obj.aggregate === true && typeof obj.iteration === "number" && isReviewVerdict(obj.verdict)) {
      const panelId = typeof obj.panel_id === "string" ? obj.panel_id : null
      const members = entries
        .filter((entry) => entry.aggregate !== true && entry.iteration === obj.iteration && entry.panel_id === panelId)
        .flatMap(parsePanelMember)
      result.push({
        iteration: obj.iteration,
        critique: typeof obj.critique === "string" ? obj.critique : "",
        verdict: obj.verdict,
        panel_id: panelId,
        aggregate: true,
        consensus:
          typeof obj.consensus === "string"
            ? obj.consensus
            : isRecord(obj.consensus) && typeof obj.consensus.at_least === "number"
              ? { at_least: obj.consensus.at_least }
              : null,
        members,
        dropped_members: Array.isArray(obj.dropped_members) ? obj.dropped_members.flatMap(parsePanelMember) : [],
        non_blocking_findings: Array.isArray(obj.non_blocking_findings) ? obj.non_blocking_findings.flatMap(parsePanelFinding) : []
      })
      continue
    }
    if (typeof obj.iteration === "number" && typeof obj.critique === "string" && isReviewVerdict(obj.verdict) && typeof obj.panel_id !== "string") {
      result.push({ iteration: obj.iteration, critique: obj.critique, verdict: obj.verdict })
    }
  }
  return result.length > 0 ? result : null
}

function isReviewVerdict(value: unknown): value is "approved" | "needs_work" | "skipped" {
  return value === "approved" || value === "needs_work" || value === "skipped"
}

function parsePanelMember(raw: unknown) {
  if (!isRecord(raw) || typeof raw.provider !== "string") return []
  return [
    {
      provider: raw.provider,
      model: typeof raw.model === "string" ? raw.model : null,
      verdict: isReviewVerdict(raw.verdict) ? raw.verdict : null,
      critique: typeof raw.critique === "string" ? raw.critique : null
    }
  ]
}

function parsePanelFinding(raw: unknown) {
  if (!isRecord(raw) || typeof raw.provider !== "string" || typeof raw.critique !== "string") return []
  return [{ provider: raw.provider, model: typeof raw.model === "string" ? raw.model : null, critique: raw.critique }]
}

export function stepArtifactSecurityReview(raw: unknown): JobSecurityReviewIteration[] | null {
  return stepArtifactAdversarialReview(raw)
}

export type VisualReviewArtifactFilter = {
  stepId?: number | null
  runId?: number | null
  iteration?: number | null
}

export function stepArtifactVisualReview(raw: unknown, filter: VisualReviewArtifactFilter = {}): JobVisualReviewIteration[] | null {
  if (!Array.isArray(raw) || raw.length === 0) return null
  const result: JobVisualReviewIteration[] = []
  for (const item of raw) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue
    const obj = item as Record<string, unknown>
    if (typeof obj.iteration !== "number") continue
    if (typeof obj.critique !== "string") continue
    if (obj.verdict !== "approved" && obj.verdict !== "needs_work" && obj.verdict !== "skipped") continue
    if (!visualReviewIterationMatches(obj, filter)) continue

    const artifacts = Array.isArray(obj.artifacts) ? obj.artifacts.flatMap(parseVisualReviewArtifact) : []
    result.push({
      iteration: obj.iteration,
      step_id: typeof obj.step_id === "number" ? obj.step_id : null,
      run_id: typeof obj.run_id === "number" ? obj.run_id : null,
      critique: obj.critique,
      verdict: obj.verdict,
      artifacts
    })
  }
  return result.length > 0 ? result : null
}

function visualReviewIterationMatches(obj: Record<string, unknown>, filter: VisualReviewArtifactFilter) {
  if (typeof filter.runId === "number" && typeof obj.run_id === "number") return obj.run_id === filter.runId
  if (typeof filter.stepId === "number" && typeof obj.step_id === "number") return obj.step_id === filter.stepId
  // Legacy entries recorded before run/step provenance was stamped onto
  // iterations carry neither id -- fall back to loop-position matching when
  // there is one, and otherwise treat the entry as unattributable rather
  // than dropping it (a single-run, non-looped step has nothing else to
  // disambiguate against, so hiding it here would just delete history).
  if (typeof obj.run_id !== "number" && typeof obj.step_id !== "number") {
    if (typeof filter.iteration === "number") return obj.iteration === filter.iteration
    return true
  }
  return false
}

function parseVisualReviewArtifact(raw: unknown): JobVisualReviewArtifact[] {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return []
  const obj = raw as Record<string, unknown>
  if (typeof obj.type !== "string") return []
  return [
    {
      type: obj.type,
      title: typeof obj.title === "string" ? obj.title : null,
      image_url: typeof obj.image_url === "string" ? obj.image_url : null,
      content_type: typeof obj.content_type === "string" ? obj.content_type : null,
      byte_size: typeof obj.byte_size === "number" ? obj.byte_size : null,
      page: isRecord(obj.page) ? obj.page : null,
      viewport: isRecord(obj.viewport) ? obj.viewport : null,
      source: typeof obj.source === "string" ? obj.source : null,
      captured_at: typeof obj.captured_at === "string" ? obj.captured_at : null,
      created_at: typeof obj.created_at === "string" ? obj.created_at : null
    }
  ]
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}
