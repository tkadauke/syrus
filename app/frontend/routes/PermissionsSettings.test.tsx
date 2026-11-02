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

    fireEvent.click(await screen.findByRole("button", { name: "Add rule" }))

    expect(await screen.findByText("authority exceeds the effective policy ceiling")).toBeInTheDocument()
  })

  it("shows a failed revoke instead of silently leaving the rule active", async () => {
    vi.spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(jsonResponse({ error: { code: "invalid_permission_rule", message: "rule could not be revoked" } }, 422))
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: "Revoke" }))

    expect(await screen.findByText("rule could not be revoked")).toBeInTheDocument()
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
        owner: { kind: "provider", name: "syrus" },
        editable: false,
        explanation: "role_default"
      }
    ]
  }
}
