import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
  installations: [{ id: 1, account_login: "tkadauke", github_installation_id: 999, installed_at: "2026-01-01T00:00:00Z", removed_at: null, active: true }],
  repositories: [
    {
      id: 1,
      slug: "tkadauke/syrus",
      credential_mode: "app",
      app_credential_active: true,
      app_credential_inactive_reason: null,
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

  it("renders global state, sync timing, and repository/installation tables", () => {
    render(<>{adminGithubAppInstallationDiagnosticToolCard.renderExpanded(context({ parsedResult: HEALTHY_PAYLOAD }))}</>)

    expect(screen.getByText("registered")).toBeInTheDocument()
    expect(screen.getByText("jwt usable")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("tkadauke")).toBeInTheDocument()
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

    expect(screen.getByText("jwt unusable")).toBeInTheDocument()
    expect(screen.getByText("invalid private key")).toBeInTheDocument()
    expect(screen.getByText("Octokit::Unauthorized: Bad credentials")).toBeInTheDocument()
    expect(screen.getByText("linked installation removed")).toBeInTheDocument()
    expect(screen.getByText("reinstall app for owner or repo")).toBeInTheDocument()
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
})
