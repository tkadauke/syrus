import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { jsonResponse } from "../testSupport"
import { PermissionsSettingsRoute } from "./PermissionsSettings"

describe("PermissionsSettingsRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("separates editable user rules from inherited read-only policy", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse(payload()))
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))

    expect((await screen.findAllByText("syrus.jobs@v1 · cancel@v1")).length).toBeGreaterThanOrEqual(2)
    expect(screen.getByRole("button", { name: "Revoke" })).toBeInTheDocument()
    const inherited = screen.getByRole("heading", { name: "Inherited policy" }).parentElement!
    expect(within(inherited).getAllByText("Read only")).toHaveLength(2)
    expect(within(inherited).getAllByText(/are decisive/)).toHaveLength(2)
    expect(screen.getByRole("link", { name: "Open operational dashboard" })).toHaveAttribute("href", "/dashboard")
  })

  it("creates a scoped user rule", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(jsonResponse({ rule: payload().rules[0] }, 201))
      .mockResolvedValue(jsonResponse(payload()))
    renderRoute()
    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))
    await screen.findByRole("combobox", { name: "Policy" })
    fireEvent.click(screen.getByRole("button", { name: "Add rule" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/permission_rules", expect.objectContaining({ method: "POST" })))
    const call = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/permission_rules" && init?.method === "POST")!
    expect(JSON.parse(String(call[1]?.body)).permission_rule).toMatchObject({
      policy: "allow",
      subject_selector_type: "interactive_chat",
      capability: "syrus.jobs@v1"
    })
  })

  it("shows a failed create instead of silently leaving the form unchanged", async () => {
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(jsonResponse({ error: { code: "invalid_permission_rule", message: "authority exceeds the effective policy ceiling" } }, 422))
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))

    fireEvent.click(await screen.findByRole("button", { name: "Add rule" }))

    expect(await screen.findByText("authority exceeds the effective policy ceiling")).toBeInTheDocument()
  })

  it("shows a failed revoke instead of silently leaving the rule active", async () => {
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(jsonResponse({ error: { code: "invalid_permission_rule", message: "rule could not be revoked" } }, 422))
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))

    fireEvent.click(await screen.findByRole("button", { name: "Revoke" }))

    expect(await screen.findByText("rule could not be revoked")).toBeInTheDocument()
  })

  it("previews every selected matrix grant before applying it", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(
        jsonResponse({
          preview: [
            {
              action: "grant",
              policy: "allow",
              subject: "interactive_chat",
              capability: "syrus.jobs@v1",
              operation: "cancel@v1",
              resource_scope_label: "All resources"
            }
          ],
          confirmation_digest: "signed-preview"
        })
      )
      .mockResolvedValueOnce(jsonResponse({ rules: [] }))
      .mockResolvedValue(jsonResponse(payload()))
    renderRoute()

    fireEvent.click(await screen.findByRole("checkbox", { name: "Select syrus.jobs@v1 cancel@v1" }))
    fireEvent.click(screen.getByRole("button", { name: "Allow selected (1)" }))
    expect(await screen.findByRole("dialog", { name: "Confirm permission changes" })).toHaveTextContent("syrus.jobs@v1")
    fireEvent.click(screen.getByRole("button", { name: "Confirm changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/permission_rules/bulk", expect.objectContaining({ method: "POST" })))
    const call = fetchSpy.mock.calls.find(([path]) => path === "/api/v1/app/permission_rules/bulk")!
    expect(JSON.parse(String(call[1]?.body))).toMatchObject({ confirmation_digest: "signed-preview" })
  })

  it("shows when an effective matrix state varies by resource", async () => {
    const response = payload()
    response.inherited[0].matrix_states.interactive_chat = "scoped"
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse(response))

    renderRoute()

    expect(await screen.findByText("Varies by resource")).toBeInTheDocument()
  })

  it("shows active lease lifecycle and redacted authorization history", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
      if (String(input).endsWith("/history")) {
        return Promise.resolve(jsonResponse(historyPayload()))
      }
      return Promise.resolve(jsonResponse(payload()))
    })
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Active leases" }))
    expect(await screen.findByRole("heading", { name: "Active permission leases" })).toBeInTheDocument()
    expect(await screen.findByText("1 / 3")).toBeInTheDocument()
    expect(screen.getByText("Fix stuck job")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "History" }))
    expect(await screen.findByText("Authorization request")).toBeInTheDocument()
    expect(screen.getByText("Repeated requests were escalated into this decision.")).toBeInTheDocument()
    expect(screen.getByText(/\[redacted\]/)).toBeInTheDocument()
  })
})

function renderRoute() {
  render(
    <MemoryRouter>
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <PermissionsSettingsRoute />
      </QueryClientProvider>
    </MemoryRouter>
  )
}

function payload() {
  return {
    rules: [
      {
        id: 4,
        policy: "allow",
        capability: "syrus.jobs@v1",
        operation: "cancel@v1",
        subject_selector_type: "interactive_chat",
        subject_selector_id: null,
        resource_scope: {},
        resource_scope_label: "All resources",
        resource_type: "none",
        rationale: null,
        revoked_at: null,
        editable: true,
        owner: { kind: "user", id: 1, name: "Thomas" }
      }
    ],
    inherited: [
      {
        capability: "attach_repository@v1",
        operation: "attach_repository/attach_repository@v1",
        effects: ["internal_write"],
        risk: "medium",
        defaults: { "chat:planner": "ask" },
        requestable_roles: ["chat:planner"],
        authority_durations: ["invocation"],
        matrix_states: { interactive_chat: "ask", coding_chat: "deny", local_chat: "deny" },
        presets: [],
        owner: { kind: "provider", name: "attach_repository@v1" },
        editable: false,
        explanation: "role_default"
      },
      {
        capability: "syrus.jobs@v1",
        operation: "cancel@v1",
        effects: ["internal_write"],
        risk: "medium",
        defaults: { "chat:planner": "ask" },
        requestable_roles: ["chat:planner"],
        authority_durations: ["invocation", "permanent"],
        matrix_states: { interactive_chat: "ask", coding_chat: "deny", local_chat: "deny" },
        presets: [],
        owner: { kind: "provider", name: "syrus" },
        editable: false,
        explanation: "role_default"
      }
    ]
  }
}

function historyPayload() {
  return {
    active_leases: [
      {
        id: 9,
        capability: "syrus.jobs@v1",
        operation: "cancel@v1",
        subject: "workflow_role",
        duration: "job",
        resource_type: "job",
        resource_scope: { job_id: 12 },
        used_count: 1,
        max_uses: 3,
        expires_at: null,
        revoked_at: null,
        issued_at: "2026-11-02T10:00:00Z",
        issued_by: { type: "User", id: 1, label: "Thomas" },
        revoked_by: null,
        origin: { type: "Job", id: 12, label: "Fix stuck job" }
      }
    ],
    history: [
      {
        type: "request",
        id: 8,
        occurred_at: "2026-11-02T10:00:00Z",
        state: "confirmed",
        escalated: true,
        non_actionable_reason: null,
        origins: [{ label: "Fix stuck job" }],
        items: [
          {
            id: 2,
            capability: "syrus.jobs@v1",
            operation: "cancel@v1",
            state: "approved",
            selected_duration: "job",
            decision_reason: "Operator approved",
            evidence: { api_token: "[redacted]" }
          }
        ]
      }
    ]
  }
}
