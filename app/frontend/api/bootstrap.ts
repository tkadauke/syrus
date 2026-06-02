import { getJson } from "./client"
import type { SetupStatusPayload } from "./setup"

export type BootstrapPayload = {
  current_user: {
    id: number
    email_address: string
    name: string | null
    display_name: string
    admin: boolean
    scheduling_paused: boolean
    landing_paused: boolean
    agent_provider: "claude" | "codex"
    agent_max_turns: number
  } | null
  app: {
    revision: string
    revision_url: string | null
  }
  navigation?: {
    default_chat_path: string
  }
  setup?: SetupStatusPayload | null
  flash?: {
    alert?: string | null
    notice?: string | null
  }
  csrf_token: string
  feature_flags: {
    migrated_routes: string[]
  }
}

export function fetchBootstrap() {
  return getJson<BootstrapPayload>("/api/v1/app/bootstrap")
}

export function readInitialBootstrap() {
  const element = document.getElementById("syrus-bootstrap-data")
  if (!element?.textContent) return null

  try {
    return JSON.parse(element.textContent) as BootstrapPayload
  } catch {
    return null
  }
}
