import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
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
    expect(within(inherited).getByText("Read only")).toBeInTheDocument()
    expect(within(inherited).getByText(/are decisive/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open operational approvals" })).toHaveAttribute("href", "/permissions/inbox")
  })

  it("creates a scoped user rule", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValueOnce(jsonResponse(payload()))
      .mockResolvedValueOnce(jsonResponse({ rule: payload().rules[0] }, 201))
      .mockResolvedValue(jsonResponse(payload()))
    renderRoute()
    fireEvent.change(await screen.findByRole("combobox", { name: "Policy" }), { target: { value: "deny" } })
    fireEvent.click(screen.getByRole("button", { name: "Add rule" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/permission_rules", expect.objectContaining({ method: "POST" })))
    const call = fetchSpy.mock.calls.find(([path, init]) => path === "/api/v1/app/permission_rules" && init?.method === "POST")!
    expect(JSON.parse(String(call[1]?.body)).permission_rule).toMatchObject({ policy: "deny", subject_selector_type: "interactive_chat" })
  })
})

function renderRoute() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <PermissionsSettingsRoute />
    </QueryClientProvider>
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
        capability: "syrus.jobs@v1",
        operation: "cancel@v1",
        effects: ["internal_write"],
        risk: "medium",
        defaults: { "chat:planner": "ask" },
        owner: { kind: "provider", name: "syrus" },
        editable: false,
        explanation: "role_default"
      }
    ]
  }
}
