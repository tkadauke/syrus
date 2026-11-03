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
    expect(screen.getByRole("link", { name: "Open approval inbox" })).toHaveAttribute("href", "/permissions/inbox")
  })

  it("creates a rule through the shared editor's preview and apply contract", async () => {
    const fetchSpy = mockHub()
    renderRoute()
    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))
    fireEvent.click(await screen.findByRole("button", { name: "New rule" }))
    fireEvent.change(await screen.findByLabelText("Capability"), { target: { value: "syrus.jobs@v1|cancel@v1" } })
    fireEvent.change(await screen.findByLabelText("Applies to"), { target: { value: "interactive_chat" } })
    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))
    expect(await screen.findByText("Effective rule")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(screen.getByText("Rule saved")).toBeInTheDocument())
    const apply = fetchSpy.mock.calls.find(([path]) => String(path).endsWith("/permission_rule_drafts/apply"))!
    expect(JSON.parse(String(apply[1]?.body))).toMatchObject({
      digest: "hub-digest",
      draft: { policy: "allow", subject_selector_type: "interactive_chat", capability: "syrus.jobs@v1", operation: "cancel@v1" }
    })
  })

  it("edits an existing rule by replacing it through the editor", async () => {
    const fetchSpy = mockHub()
    renderRoute()
    fireEvent.click(await screen.findByRole("button", { name: "Rules" }))
    fireEvent.click(await screen.findByRole("button", { name: "Edit" }))
    expect(await screen.findByRole("heading", { name: "Edit permission rule" })).toBeInTheDocument()
    await screen.findByLabelText("Applies to")
    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))
    fireEvent.click(await screen.findByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(screen.getByText("Rule saved")).toBeInTheDocument())
    const apply = fetchSpy.mock.calls.find(([path]) => String(path).endsWith("/permission_rule_drafts/apply"))!
    expect(JSON.parse(String(apply[1]?.body))).toMatchObject({ replace_rule_id: 4 })
  })

  it("opens the editor prefilled from a card's deep link", async () => {
    const fetchSpy = mockHub()
    renderRoute("/settings/permissions?request=7&item=9")

    expect(await screen.findByRole("heading", { name: "Customize permission rule" })).toBeInTheDocument()
    const call = fetchSpy.mock.calls.find(([path]) => String(path).endsWith("/permission_rule_drafts/from_request"))!
    expect(JSON.parse(String(call[1]?.body))).toMatchObject({ request_id: 7, item_id: 9 })
  })

  it("highlights the rule a card links to", async () => {
    mockHub()
    renderRoute("/settings/permissions?rule=4")

    const rule = await screen.findByRole("article", { current: true })
    expect(rule).toHaveAttribute("id", "permission-rule-4")
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

const hubPreview = {
  valid: true,
  errors: [],
  warnings: [],
  digest: "hub-digest",
  draft: {
    policy: "allow",
    duration: "permanent",
    role: "chat:planner",
    subject: { type: "interactive_chat", id: null, subject_type: null, repository_id: null },
    capability: "syrus.jobs@v1",
    operation: "cancel@v1",
    resource_scope: {},
    resource_scope_label: "All resources",
    constraints: {},
    chat_session_id: null,
    job_id: null,
    expires_at: null,
    rationale: null
  },
  summary: { allows: ["Allows interactive chats to run cancel@v1."], excludes: ["Excludes every other operation and capability."] },
  ceiling: { maximum_autonomy: "permanent", maximum_duration_seconds: null, permanent_allowed: true, limited_by: null },
  examples: { matches: ["interactive chats running cancel@v1."], non_matches: ["Anyone else."] }
}
const hubOptions = {
  capability: "syrus.jobs@v1",
  operation: "cancel@v1",
  policies: ["allow", "ask", "deny"],
  risk: "medium",
  subject_types: [{ type: "interactive_chat", requires_id: false, requires_repository: false, roles: ["chat:planner"], exact_agent: false }],
  resource_scope: { type: "none", options: null },
  constraint_fields: {},
  authority_durations: ["chat_session", "job", "permanent"],
  maximum_autonomy: "permanent",
  maximum_duration_seconds: null,
  permanent_allowed: true,
  ceilings: []
}

function mockHub() {
  return vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
    const path = String(input)
    if (path.includes("/permission_rule_drafts/options")) return Promise.resolve(jsonResponse({ options: hubOptions }))
    if (path.endsWith("/permission_rule_drafts/preview") || path.endsWith("/permission_rule_drafts/from_request"))
      return Promise.resolve(jsonResponse({ preview: hubPreview }))
    if (path.endsWith("/permission_rule_drafts/apply"))
      return Promise.resolve(jsonResponse({ authority: { kind: "PermissionRule", id: 5, capability: "syrus.jobs@v1", operation: "cancel@v1" } }, 201))
    return Promise.resolve(jsonResponse(payload()))
  })
}

function renderRoute(entry = "/") {
  render(
    <MemoryRouter initialEntries={[entry]}>
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
