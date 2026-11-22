import { getJson, getRecentApiRequests } from "./client"
import type { ColorTheme } from "./themes"
import type { ChatModelOption, ChatProviderOption, ChatSpeechToTextCapability } from "./chats"
import { checkApiVersion } from "./version"
import { markStartupMilestone, reportStartupFailure } from "../lib/startupDiagnostics"

export type SystemAlertAction =
  | {
      text: string
      kind: "reauthorize_provider"
      provider: string
      destructive?: boolean
    }
  | {
      text: string
      method: "post" | string
      path: string
      params?: Record<string, unknown>
      destructive?: boolean
      kind?: string
      provider?: string
    }

export type BootstrapPayload = {
  v: number
  current_user: {
    id: number
    email_address: string
    display_name: string
    admin: boolean
    role: string
    agent_provider: string
    chat_provider: string | null
    theme: "light" | "dark" | "system"
    color_theme_id?: number | null
    color_theme?: ColorTheme | null
    locale: "en" | "de" | "la"
    seen_tours?: string[]
    sidebar_nav_order?: string[]
    mobile_chat_auto_hide_header?: boolean
  } | null
  time_zones?: {
    server: { name: string; source: "SYRUS_TIME_ZONE" | "TZ" | "default" }
    user: { name: string; mode: "automatic" | "manual" } | null
  }
  team_user_count: number
  chat_capabilities?: {
    speech_to_text?: ChatSpeechToTextCapability
    coding_mode_enabled?: boolean
    local_mode_enabled?: boolean
    chat_provider_options?: ChatProviderOption[]
    available_chat_models?: Record<string, ChatModelOption[]>
  }
  app: {
    enabled_plugins?: string[]
    external_plugin_frontends?: ExternalPluginFrontend[]
    revision: string
    revision_url: string | null
    // Display identity for the backend: a release version, a commits-ahead
    // description for non-release images, or the revision as a fallback.
    version: string | null
    // When the backend image was built (SYRUS_BUILT_AT, UTC ISO-8601); null
    // when the image predates the stamp. Feeds the badge's hover tooltip.
    built_at: string | null
    // Which submission path the bug-report dialog will take for this user.
    bug_report_mode: "direct_job" | "github_issue" | null
    // The configured report_issue_repo_slug (e.g. "tkadauke/syrus"); used
    // in the GitHub-issue indicator line shown inside the dialog.
    report_issue_repo_slug: string
    ui_engagement_telemetry_enabled?: boolean
  }
  setup: {
    complete: boolean
    chat_started: boolean
    first_epic_landed: boolean
    onboarding_chat_started: boolean
  } | null
  public?: {
    first_signup: boolean
    signups_open: boolean
    signup_path: string
    sign_in_path: string
    docs_url: string
    evaluation_url: string
  }
  flash?: {
    alert?: string | null
    notice?: string | null
  }
  system_alerts?: Array<{
    id: string
    dismissal_key: string
    severity: "alarm" | "warn" | "info" | string
    title: string
    message: string
    action_steps: string[]
    cta: {
      text: string
      path: string
    } | null
    actions?: SystemAlertAction[]
  }>
  unread_notifications_count: number
  csrf_token: string
  slug_refs?: {
    types: SlugReferenceType[]
  }
  feature_flags: Record<string, boolean>
}

export type ExternalPluginFrontend = {
  name: string
  bundle_url: string
  css_url?: string
  hash: string
  locales?: Array<{ locale: "en" | "de" | "la"; namespace: string; url: string }>
}

export type SlugReferenceType = {
  prefix: string
  type: string
  display_label: string
  copyable: boolean
  linkable: boolean
  preview_available: boolean
  linkifies_generated_text: boolean
  href_template: string | null
  mobile_interaction_hints: Record<string, string>
}

// A request that never got an HTTP response -- a pod restarting during a
// rollout, a mobile browser suspending a backgrounded tab mid-request -- rejects
// with a bare TypeError ("Load failed" in Safari, "Failed to fetch" in Chrome).
// Those are retried here before startup is declared failed; the single query
// retry outlasted neither, and every one was recorded as a startup failure even
// when the next attempt worked. An HTTP error response is a real answer and
// fails at once, as before.
export const BOOTSTRAP_NETWORK_RETRY_DELAYS_MS = [400, 1500]

function networkFailure(error: unknown) {
  return error instanceof TypeError
}

function wait(ms: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, ms))
}

export function fetchBootstrap() {
  return fetchBootstrapWithRetries(wait)
}

export async function fetchBootstrapWithRetries(sleep: (ms: number) => Promise<void>) {
  markStartupMilestone("bootstrap_fetch_started")
  for (let attempt = 0; ; attempt += 1) {
    try {
      const payload = await getJson<BootstrapPayload>("/api/v1/app/bootstrap")
      markStartupMilestone("bootstrap_fetch_succeeded")
      return payload
    } catch (error) {
      const delay = BOOTSTRAP_NETWORK_RETRY_DELAYS_MS[attempt]
      if (networkFailure(error) && delay !== undefined) {
        await sleep(delay)
        continue
      }
      reportStartupFailure("bootstrap_fetch", error, { request_correlation: getRecentApiRequests().slice(-1)[0] ?? null })
      throw error
    }
  }
}

export function readInitialBootstrap() {
  if (typeof document === "undefined") return null

  const element = document.getElementById("syrus-bootstrap-data")
  if (!element?.textContent) return null

  try {
    const payload = JSON.parse(element.textContent) as BootstrapPayload
    checkApiVersion(payload)
    return payload
  } catch {
    return null
  }
}
