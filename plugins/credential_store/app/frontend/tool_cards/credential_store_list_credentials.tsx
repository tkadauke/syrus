import { CodeSurface } from "@app/components/ui"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"

function credentialCount(context: ToolCardContext): number | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.credentials)) return null
  return parsed.credentials.length
}

const credentialStoreListCredentialsToolCard: ToolCardRenderer = {
  toolName: "credential_store_list_credentials",
  readOnly: true,
  collapsedSummary(context) {
    const count = credentialCount(context)
    return count == null ? null : String(count)
  },
  renderExpanded(context) {
    if (!isPlainObject(context.parsedResult) || !Array.isArray(context.parsedResult.credentials)) return null

    // The discovery response contains only server-selected safe columns. A
    // dedicated JSON surface prevents the generic text scrubber from
    // mistaking identifier values such as `credential_store.url_token` for
    // secret material after the structured redactor has already run.
    return <CodeSurface code={JSON.stringify(context.parsedResult, null, 2)} lang="json" maxHeightClassName="max-h-72" />
  }
}

export const examples: ToolCardExample[] = [
  {
    id: "multiple_scopes_with_long_metadata",
    label: "Multiple credentials with long metadata",
    description: "Exercises the collapsed count, generic expanded JSON, and narrow-width overflow with repository, team, and instance scopes.",
    input: { limit: 20 },
    parsedResult: {
      credentials: [
        {
          id: 41,
          reference: "41",
          name: "Home Assistant production automation token with a deliberately long display name",
          description: "Read-only automation credential for climate, lighting, presence, and energy dashboards across the primary residence.",
          credential_type: "credential_store.url_token",
          scope: "repository",
          scope_id: 17,
          scope_label: "green-acres/home-automation-and-observability",
          safe_metadata: {
            base_url: "https://home-assistant.internal.example.net:8123/api/",
            host: "home-assistant.internal.example.net",
            username: "automation-planner"
          },
          target_constraints: {
            allowed_url_prefixes: [
              "https://home-assistant.internal.example.net:8123/api/states/",
              "https://home-assistant.internal.example.net:8123/api/services/"
            ]
          },
          allowed_surfaces: ["chat", "workflow"],
          allowed_tools: ["home_assistant.read", "home_assistant.plan_automation"],
          expires_at: "2027-02-01T09:30:00Z",
          last_rotated_at: "2026-11-01T08:15:00Z",
          expiration_status: "active_until_expiration",
          rotation_status: "rotated"
        },
        {
          id: 73,
          reference: "73",
          name: "Platform deployment SSH key",
          description: "Team credential constrained to the production deployment bastion.",
          credential_type: "credential_store.ssh_private_key",
          scope: "team",
          scope_id: 8,
          scope_label: "Platform Engineering",
          safe_metadata: {
            host: "production-bastion-with-a-very-long-dns-name.internal.example.net",
            username: "deploy",
            fingerprint: "SHA256:3wB7kM9FQxvH4JpL6tNc2sR8yZd1aEg5uOi0CAbDeFg"
          },
          target_constraints: {
            allowed_hosts: ["production-bastion-with-a-very-long-dns-name.internal.example.net"]
          },
          allowed_surfaces: ["workflow"],
          allowed_tools: ["credential_store_ssh_exec"],
          expires_at: null,
          last_rotated_at: "2026-10-15T12:00:00Z",
          expiration_status: "does_not_expire",
          rotation_status: "rotated"
        },
        {
          id: 96,
          reference: "96",
          name: "Shared monitoring API credential",
          description: "Instance-visible metadata for planning read-only monitoring queries.",
          credential_type: "credential_store.url_token",
          scope: "instance",
          scope_id: null,
          scope_label: "Instance",
          safe_metadata: { host: "monitoring.internal.example.net", refreshable: true },
          target_constraints: { allowed_url_prefixes: ["https://monitoring.internal.example.net/api/v1/query"] },
          allowed_surfaces: ["chat", "workflow"],
          allowed_tools: ["monitoring.query"],
          expires_at: null,
          last_rotated_at: null,
          expiration_status: "does_not_expire",
          rotation_status: "not_recorded"
        }
      ],
      count: 3,
      limit: 20,
      access_notice:
        "Discovery returns non-secret metadata only and does not grant credential use. Execution still requires broker authorization, permissions, leases, target checks, and audit logging."
    },
    sourceType: "generic"
  }
]

export default credentialStoreListCredentialsToolCard
