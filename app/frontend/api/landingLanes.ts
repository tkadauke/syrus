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

export type LandingLanesRepository = {
  id: number
  slug: string
  landing_concurrency: number
  busy_lane_count: number
  approved_backlog: Array<LandingLaneJob & { position: number }>
  lanes: LandingLane[]
}

export type LandingLanesPayload = {
  estimate_kind: "best_case"
  repositories: LandingLanesRepository[]
}

export function fetchLandingLanes({ signal }: { signal?: AbortSignal } = {}) {
  return getJson<LandingLanesPayload>("/api/v1/app/landing_lanes", { signal })
}
