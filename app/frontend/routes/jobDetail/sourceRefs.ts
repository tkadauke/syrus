// Source-browser ref/search helpers extracted from JobDetail.tsx.
//
// Build the ref picker options (merge base + branch commits + any active
// refs) and the source/diff query strings. Pure over the job source payload
// ref fields; lifted out of the 3k-line JobDetail.tsx.
import type { JobSourcePayload } from "../../api/jobs"

export type SourceRefPayload = Pick<JobSourcePayload, "merge_base_sha" | "default_ref" | "branch_commits">

export function refOptionsFor(payload: SourceRefPayload, activeRefs: Array<string | null | undefined> = []) {
  const options = new Map<string, string>()
  options.set(payload.merge_base_sha || payload.default_ref, `Merge base (${(payload.merge_base_sha || payload.default_ref).slice(0, 7)})`)
  payload.branch_commits.forEach((commit) => options.set(commit.sha, `${commit.short_sha} ${commit.message}`))
  activeRefs.forEach((ref) => {
    if (ref && !options.has(ref)) options.set(ref, ref.slice(0, 12))
  })

  return Array.from(options, ([value, label]) => ({ value, label }))
}

export function sourceSearch(ref: string | null, path: string | null, treePath: string | null = null) {
  const params = new URLSearchParams()
  if (ref) params.set("ref", ref)
  if (path) params.set("path", path)
  if (treePath) params.set("tree_path", treePath)
  const value = params.toString()
  return value ? `?${value}` : ""
}

export function sourceDiffSearch(baseRef: string | null, headRef: string | null) {
  const params = new URLSearchParams()
  if (baseRef) params.set("base", baseRef)
  if (headRef) params.set("head", headRef)
  const value = params.toString()
  return value ? `?${value}` : ""
}
