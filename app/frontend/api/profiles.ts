import { getJson } from "./client"

export type TeamProfileCounts = {
  repositories: number
  epics: number
  jobs: number
  open_jobs: number
}

export type TeamProfileSummary = {
  id: number
  display_name: string
  first_name: string | null
  last_name: string | null
  github_handle: string | null
  avatar_url: string | null
  bio_excerpt: string
  counts: TeamProfileCounts
  profile_path: string
}

export type TeamProfileRepository = {
  id: number
  slug: string
  path: string
}

export type TeamProfileOwner = {
  id: number
  display_name: string
  profile_path: string
}

export type TeamProfileEpic = {
  id: number
  display_number: string
  title: string
  state: string
  repository: TeamProfileRepository
  updated_at: string | null
  path: string
}

export type TeamProfileJob = {
  id: number
  title: string
  state: string
  kind: string
  repository: TeamProfileRepository
  updated_at: string | null
  path: string
  owner?: TeamProfileOwner | null
}

export type TeamProfileActivity = {
  type: "job" | "epic"
  title: string
  state: string
  repository_slug: string
  occurred_at: string | null
  path: string
}

export type TeamProfileDetail = Omit<TeamProfileSummary, "bio_excerpt" | "profile_path"> & {
  role_label: string
  profile_bio: string | null
  profile_location: string | null
  profile_company: string | null
  profile_website: string | null
  repositories: TeamProfileRepository[]
  epics: TeamProfileEpic[]
  jobs: TeamProfileJob[]
  recent_activity: TeamProfileActivity[]
}

export type TeamProfilesPayload = {
  team_user_count: number
  profiles: TeamProfileSummary[]
}

export type TeamProfilePayload = {
  team_user_count: number
  profile: TeamProfileDetail
}

export function fetchProfiles() {
  return getJson<TeamProfilesPayload>("/api/v1/app/profiles")
}

export function fetchProfile(id: string) {
  return getJson<TeamProfilePayload>(`/api/v1/app/profiles/${id}`)
}
