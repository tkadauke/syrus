import { getJson } from "./client"

export type LandingLaneJob = {
  id: number
  slug: string
  app_path: string
}

export type LandingLaneGrader = {
  name: string
  state: string
  carried: boolean
  expected_seconds: number
  progress: number
}

export type LandingLane = {
  number: number
  empty: boolean
  draining: boolean
  landing_kind?: string
  anchor_job?: LandingLaneJob | null
  member_jobs?: LandingLaneJob[]
  workflow?: LandingLaneJob
  phase?: string
  repair_round?: number | null
  rebasing?: boolean
  multisect?: { sub_lanes: Array<{ step_id: number; role: string; round: number; state: string }> } | null
  graders?: LandingLaneGrader[]
  progress?: number
  best_case_remaining_seconds?: number
  estimate_kind?: "best_case"
}

// Lanes of one non-default landing branch (delivery track). Only branches
// with an active landing are sent.
export type LandingLanesBranch = {
  branch: string
  busy_lane_count: number
  lanes: LandingLane[]
}

export type LandingLanesRepository = {
  id: number
  slug: string
  default_branch: string
  landing_concurrency: number
  busy_lane_count: number
  approved_backlog: Array<LandingLaneJob & { position: number }>
  // The default branch's lanes.
  lanes: LandingLane[]
  additional_branches: LandingLanesBranch[]
}

export type LandingLaneSection = { branch: string | null; lanes: LandingLane[] }

// The repository's lanes grouped by landing branch. A repository landing only
// to its default branch has a single unlabelled section.
export function landingLaneSections(repository: LandingLanesRepository): LandingLaneSection[] {
  const additional = repository.additional_branches ?? []
  if (additional.length === 0) return [{ branch: null, lanes: repository.lanes }]

  return [{ branch: repository.default_branch, lanes: repository.lanes }, ...additional.map(({ branch, lanes }) => ({ branch, lanes }))]
}

export type LandingLanesPayload = {
  estimate_kind: "best_case"
  repositories: LandingLanesRepository[]
}

export function fetchLandingLanes({ signal }: { signal?: AbortSignal } = {}) {
  return getJson<LandingLanesPayload>("/api/v1/app/landing_lanes", { signal })
}
