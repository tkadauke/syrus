import type { BootstrapPayload } from "./bootstrap"
import { getJson } from "./client"

export type MePayload = Pick<BootstrapPayload, "current_user" | "team_user_count" | "unread_notifications_count">

export function fetchMe() {
  return getJson<MePayload>("/api/v1/app/me")
}

export type SeenToursPayload = { seen_tours: string[] }
