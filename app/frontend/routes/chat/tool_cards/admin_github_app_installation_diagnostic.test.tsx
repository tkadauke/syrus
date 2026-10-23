import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { redactToolCardValue } from "../../../toolCardSecurity"
import { normalizedToolCardParsedResult, toolResultPresentation } from "../toolRendering"
import adminGithubAppInstallationDiagnosticToolCard from "./admin_github_app_installation_diagnostic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "admin_github_app_installation_diagnostic",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const HEALTHY_PAYLOAD = {
  global: {
    app_id_present: true,
    slug_present: true,
    private_key_present: true,
    registered_at: "2026-01-01T00:00:00Z",
    registered: true,
    jwt_usable: true,
    jwt_error_class: null,
    jwt_error_message: null
  },
  latest_sync: {
    last_attempted_at: "2026-09-06T00:00:00Z",
    last_successful_at: "2026-09-06T00:00:00Z",
    duration_ms: 120,
    records_seen: 3,
    error_class: null,
    error_message: null
  },
  installations: [
    {
      id: 10,
      account_login: "tkadauke",
      account_id: 20,
      account_type: "Organization",
      github_installation_id: 999,
      installed_at: "2026-01-01T00:00:00Z",
      removed_at: null,
      active: true
    }
  ],
  repositories: [
    {
      id: 1,
      slug: "tkadauke/syrus",
      owner: "tkadauke",
      name: "syrus",
      github_owner_id: 20,
      github_repository_id: 30,
      installation_id: 10,
      credential_mode: "app",
      app_credential_active: true,
      app_credential_inactive_reason: null,
      scoped_install_url: "https://github.com/apps/syrus/installations/new/permissions?target_id=20",
      install_url_missing_reason: null,
      repository_installation: {
        id: 10,
        account_login: "tkadauke",
        account_id: 20,
        account_type: "Organization",
        github_installation_id: 999,
        installed_at: "2026-01-01T00:00:00Z",
        removed_at: null,
        active: true
      },
      membership_installations: [
        {
          user_id: 40,
          user_email: "operator@example.com",
          role: "owner",
          installation_id: 10,
          effective_client_installation_id: 10,
          installation: {
            id: 11,
            account_login: "member-account",
            account_id: 21,
            account_type: "User",
            github_installation_id: 1000,
            installed_at: "2026-02-01T00:00:00Z",
            removed_at: "2026-03-01T00:00:00Z",
            active: false
          }
        }
      ],
      recommended_next_action: "none"
    }
  ],
  recommended_next_action: "none"
}

describe("admin_github_app_installation_diagnostic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(adminGithubAppInstallationDiagnosticToolCard.toolName).toBe("admin_github_app_installation_diagnostic")
  })

  it("summarizes a healthy instance in the collapsed row", () => {
    expect(adminGithubAppInstallationDiagnosticToolCard.collapsedSummary?.(context({ parsedResult: HEALTHY_PAYLOAD }))).toBe("1 repository checked")
  })

  it("summarizes an unregistered app distinctly", () => {
    const parsedResult = { ...HEALTHY_PAYLOAD, global: { ...HEALTHY_PAYLOAD.global, registered: false } }
    expect(adminGithubAppInstallationDiagnosticToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("GitHub App not registered")
  })

  it("summarizes a recommended action when one is present", () => {
    const parsedResult = { ...HEALTHY_PAYLOAD, recommended_next_action: "refresh_installations" }
    expect(adminGithubAppInstallationDiagnosticToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Action needed: refresh installations")
  })

  it("renders every registration, sync, installation, repository, and membership diagnostic", () => {
    render(
      <>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ input: { repository: "tkadauke/syrus" }, parsedResult: HEALTHY_PAYLOAD }))}</>
    )

    expect(screen.getByText("registered")).toBeInTheDocument()
    expect(screen.getByText("usable")).toBeInTheDocument()
    expect(screen.getAllByText("tkadauke/syrus")).toHaveLength(2)
    expect(screen.getAllByText("Organization").length).toBeGreaterThan(0)
    expect(screen.getByText("operator@example.com")).toBeInTheDocument()
    expect(screen.getByText("11")).toBeInTheDocument()
    expect(screen.getByText("member-account")).toBeInTheDocument()
    expect(screen.getByText("21")).toBeInTheDocument()
    expect(screen.getByText("User")).toBeInTheDocument()
    expect(screen.getByText("1000")).toBeInTheDocument()
    expect(screen.getByText("2026-02-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("2026-03-01T00:00:00Z")).toBeInTheDocument()
    expect(screen.getByText("removed")).toBeInTheDocument()
    expect(screen.getByText("120")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open scoped GitHub App installation" })).toHaveAttribute("target", "_blank")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/1")
    expect(screen.getAllByText("No operator action is currently recommended.")).toHaveLength(2)
  })

  it("surfaces a failed installation sync and an inactive repository's reason", () => {
    const parsedResult = {
      ...HEALTHY_PAYLOAD,
      global: { ...HEALTHY_PAYLOAD.global, jwt_usable: false, jwt_error_message: "invalid private key" },
      latest_sync: { ...HEALTHY_PAYLOAD.latest_sync, error_class: "Octokit::Unauthorized", error_message: "Bad credentials" },
      repositories: [
        {
          id: 1,
          slug: "tkadauke/syrus",
          credential_mode: "pat",
          app_credential_active: false,
          app_credential_inactive_reason: "linked_installation_removed",
          recommended_next_action: "reinstall_app_for_owner_or_repo"
        }
      ]
    }

    render(<>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("unusable")).toBeInTheDocument()
    expect(screen.getByText("invalid private key")).toBeInTheDocument()
    expect(screen.getByText("Octokit::Unauthorized: Bad credentials")).toBeInTheDocument()
    expect(screen.getByText("linked installation removed")).toBeInTheDocument()
    expect(screen.getByText("reinstall app for owner or repo")).toBeInTheDocument()
    expect(screen.getByText(/Reinstall the GitHub App/)).toBeInTheDocument()
  })

  it("renders an explicit empty state for no repositories in scope", () => {
    const parsedResult = { ...HEALTHY_PAYLOAD, repositories: [] }
    render(<>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No repositories in scope.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(adminGithubAppInstallationDiagnosticToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("renders explicit tool errors through the shared text preview", () => {
    render(<>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ resultError: true, resultBody: "token=super-secret-value failed" }))}</>)
    expect(screen.getByText("Diagnostic error")).toBeInTheDocument()
    expect(screen.getByText("token=[redacted] failed")).toBeInTheDocument()
    expect(adminGithubAppInstallationDiagnosticToolCard.collapsedSummary?.(context({ resultError: true }))).toBe("GitHub App installation diagnostic failed")
  })

  it.each([
    ["mcp__syrus-chat-sidecar__admin_github_app_installation_diagnostic", HEALTHY_PAYLOAD],
    ["admin_github_app_installation_diagnostic", { structured_content: HEALTHY_PAYLOAD, content: [] }],
    ["admin_github_app_installation_diagnostic", { structured_content: null, content: [{ type: "text", text: JSON.stringify(HEALTHY_PAYLOAD) }] }]
  ])("normalizes %s agent results to the same dedicated card", (rawName, envelope) => {
    const body = JSON.stringify(envelope)
    expect(toolResultPresentation(rawName, body)).toMatchObject({ kind: "text", summary: "1 repository checked" })
    expect(normalizedToolCardParsedResult(envelope)).toEqual(HEALTHY_PAYLOAD)
  })

  it("retains safe diagnostic metadata after whole-payload redaction", () => {
    const redacted = redactToolCardValue(HEALTHY_PAYLOAD)
    expect(redacted).toEqual(HEALTHY_PAYLOAD)
    render(<>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ parsedResult: redacted }))}</>)
    expect(screen.getByText("usable")).toBeInTheDocument()
    expect(screen.getByText("operator@example.com")).toBeInTheDocument()
  })
})
