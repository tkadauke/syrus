import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuleDraftOptions, RuleDraftPreview } from "../api/permissionRuleDrafts"
import { jsonResponse } from "../testSupport"
import { PermissionRuleEditor, type RuleEditorSeed } from "./PermissionRuleEditor"

const options: RuleDraftOptions = {
  capability: "mail@v1",
  operation: "mail/send@v1",
  policies: ["allow", "ask", "deny"],
  risk: "medium",
  subject_types: [
    { type: "interactive_chat", requires_id: false, requires_repository: false, roles: ["chat:planner"], exact_agent: false },
    { type: "agent", requires_id: true, requires_repository: false, roles: ["chat:planner"], exact_agent: true }
  ],
  resource_scope: {
    type: "mailbox",
    options: { fields: [{ name: "folder", label: "Mail folder", type: "select", choices: [{ value: "drafts", label: "Drafts" }] }] }
  },
  constraint_fields: { recipient: "string", dry_run: "boolean" },
  authority_durations: ["chat_session", "job", "permanent"],
  maximum_autonomy: "permanent",
  maximum_duration_seconds: null,
  permanent_allowed: true,
  ceilings: [{ id: 3, layer: "organization", policy: "deny", subject_selector_type: "agent" }]
}

function preview(overrides: Partial<RuleDraftPreview> = {}): RuleDraftPreview {
  return {
    valid: true,
    errors: [],
    warnings: [],
    digest: "digest-1",
    draft: {
      policy: "allow",
      duration: "permanent",
      role: "chat:planner",
      subject: { type: "interactive_chat", id: null, subject_type: null, repository_id: null },
      capability: "mail@v1",
      operation: "mail/send@v1",
      resource_scope: { folder: "drafts" },
      resource_scope_label: "Drafts",
      constraints: {},
      chat_session_id: null,
      job_id: null,
      expires_at: null,
      rationale: null
    },
    summary: {
      allows: ["Allows interactive chats to run mail/send@v1 on Drafts until revoked."],
      excludes: ["Excludes every other operation and capability."]
    },
    ceiling: { maximum_autonomy: "permanent", maximum_duration_seconds: null, permanent_allowed: true, limited_by: null },
    examples: { matches: ["interactive chats running mail/send@v1 on Drafts."], non_matches: ["Anyone other than interactive chats running mail/send@v1."] },
    ...overrides
  }
}

function setup(seed: RuleEditorSeed, handler: (path: string, init?: RequestInit) => Response) {
  const calls: Array<{ path: string; body: unknown }> = []
  vi.spyOn(globalThis, "fetch").mockImplementation((input, init) => {
    const path = String(input)
    calls.push({ path, body: init?.body ? JSON.parse(String(init.body)) : undefined })
    return Promise.resolve(handler(path, init))
  })
  const onApplied = vi.fn()
  const onCancel = vi.fn()
  render(
    <MemoryRouter>
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <PermissionRuleEditor onApplied={onApplied} onCancel={onCancel} seed={seed} />
      </QueryClientProvider>
    </MemoryRouter>
  )
  return { calls, onApplied, onCancel }
}

const standard = (path: string) => {
  if (path.includes("/options")) return jsonResponse({ options })
  if (path.endsWith("/from_request")) return jsonResponse({ preview: preview() })
  if (path.endsWith("/preview")) return jsonResponse({ preview: preview() })
  return jsonResponse({ authority: { kind: "PermissionRule", id: 42, capability: "mail@v1", operation: "mail/send@v1" } }, 201)
}

describe("PermissionRuleEditor", () => {
  afterEach(() => vi.restoreAllMocks())

  it("prefills from the exact pending call and renders scope inputs from the provider schema", async () => {
    const { calls } = setup({ kind: "request", requestId: 7, itemId: 9, duration: "permanent" }, standard)

    const scope = await screen.findByLabelText("Mail folder")
    expect(scope).toHaveValue("drafts")
    expect(calls[0]).toMatchObject({ path: "/api/v1/app/permission_rule_drafts/from_request", body: { request_id: 7, item_id: 9, duration: "permanent" } })
    expect(screen.queryByRole("textbox", { name: /json/i })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open in Permissions Hub" })).toHaveAttribute("href", "/settings/permissions?request=7&item=9")
    expect(await screen.findByText("Effective rule")).toBeInTheDocument()
    expect(screen.getByText("Representative matches")).toBeInTheDocument()
    expect(screen.getByText("Representative non-matches")).toBeInTheDocument()
    expect(screen.getByText(/Ceilings/)).toBeInTheDocument()
  })

  it("requires a current server preview before saving and applies with its digest", async () => {
    const { calls, onApplied } = setup({ kind: "request", requestId: 7, itemId: 9, duration: "permanent" }, standard)
    await screen.findByLabelText("Mail folder")

    fireEvent.change(screen.getByLabelText("Rationale (optional)"), { target: { value: "Weekly digest" } })
    expect(screen.getByRole("button", { name: "Review rule" })).toBeInTheDocument()
    expect(screen.getByText(/changed the rule since this preview/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))
    fireEvent.click(await screen.findByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(onApplied).toHaveBeenCalledWith({ id: 42, policy: "allow" }))
    const apply = calls.find((call) => call.path.endsWith("/apply"))!
    expect(apply.body).toMatchObject({ digest: "digest-1", draft: { capability: "mail@v1", rationale: "Weekly digest", resource_scope: { folder: "drafts" } } })
  })

  it("offers only descriptor durations, and constraints only on bounded allow authority", async () => {
    setup({ kind: "fields", fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat" } }, standard)
    const duration = await screen.findByLabelText("Duration")
    expect(
      within(duration)
        .getAllByRole("option")
        .map((option) => option.textContent)
    ).toEqual(["Permanent until you revoke it"])
    expect(screen.queryByText("Only when the call's arguments match")).not.toBeInTheDocument()
  })

  it("shows constraint inputs for lease-backed authority", async () => {
    setup(
      {
        kind: "fields",
        fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat", duration: "chat_session", chat_session_id: "5" }
      },
      standard
    )
    expect(await screen.findByText("Only when the call's arguments match")).toBeInTheDocument()
    expect(screen.getByLabelText("recipient")).toBeInTheDocument()
    expect(screen.getByLabelText("dry_run")).toBeInTheDocument()
  })

  it("surfaces server validation errors and never offers Save for an invalid draft", async () => {
    const { calls } = setup(
      { kind: "fields", fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat" } },
      (path) => {
        if (path.includes("/options")) return jsonResponse({ options })
        return jsonResponse(
          {
            preview: preview({ valid: false }),
            error: {
              code: "invalid_permission_draft",
              message: "A higher-level policy does not allow this authority.",
              issues: [{ code: "exceeds_policy_ceiling", message: "A higher-level policy does not allow this authority." }]
            }
          },
          422
        )
      }
    )
    await screen.findByLabelText("Duration")

    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))

    expect(await screen.findByRole("alert")).toHaveTextContent("A higher-level policy does not allow this authority.")
    expect(screen.queryByRole("button", { name: "Save rule" })).not.toBeInTheDocument()
    expect(calls.some((call) => call.path.endsWith("/apply"))).toBe(false)
  })

  it("discards a stale preview when the server reports changed permissions", async () => {
    setup({ kind: "fields", fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat" } }, (path) => {
      if (path.includes("/options")) return jsonResponse({ options })
      if (path.endsWith("/preview")) return jsonResponse({ preview: preview() })
      return jsonResponse({ error: { code: "stale_permission_preview", message: "Preview again." } }, 409)
    })
    await screen.findByLabelText("Duration")
    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))
    fireEvent.click(await screen.findByRole("button", { name: "Save rule" }))

    expect(await screen.findByText("Your permissions changed since this preview. Review the rule again.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Review rule" })).toBeInTheDocument()
  })

  it("replaces an existing rule through the same apply contract", async () => {
    const { calls, onApplied } = setup(
      { kind: "fields", replaceRuleId: 11, fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat" } },
      standard
    )
    await screen.findByLabelText("Duration")
    expect(screen.getByRole("heading", { name: "Edit permission rule" })).toHaveFocus()
    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))
    fireEvent.click(await screen.findByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(onApplied).toHaveBeenCalled())
    expect(calls.find((call) => call.path.endsWith("/apply"))!.body).toMatchObject({ replace_rule_id: 11 })
  })

  it("is keyboard dismissible and labelled for assistive tech", async () => {
    const { onCancel } = setup(
      { kind: "fields", fields: { capability: "mail@v1", operation: "mail/send@v1", subject_selector_type: "interactive_chat" } },
      standard
    )
    const form = await screen.findByRole("form", { name: "Customize permission rule" })
    await screen.findByLabelText("Duration")

    fireEvent.keyDown(form, { key: "Escape" })

    expect(onCancel).toHaveBeenCalled()
    for (const control of within(form).getAllByRole("combobox")) expect(control).toHaveAccessibleName()
  })

  it("lets the Hub pick a capability, then loads its options", async () => {
    const { calls } = setup({ kind: "blank", capabilities: [{ capability: "mail@v1", operation: "mail/send@v1" }] }, standard)
    expect(screen.getByRole("button", { name: "Review rule" })).toBeDisabled()

    fireEvent.change(screen.getByLabelText("Capability"), { target: { value: "mail@v1|mail/send@v1" } })

    expect(await screen.findByLabelText("Applies to")).toBeInTheDocument()
    expect(calls.some((call) => call.path.includes("/options?capability=mail%40v1&operation=mail%2Fsend%40v1"))).toBe(true)
  })

  it("clears hidden constraints when switching to permanent authority", async () => {
    const { calls } = setup(
      {
        kind: "fields",
        fields: {
          capability: "mail@v1",
          operation: "mail/send@v1",
          subject_selector_type: "interactive_chat",
          duration: "chat_session",
          chat_session_id: "5",
          constraints: { recipient: "a@b.c" }
        }
      },
      standard
    )
    expect(await screen.findByLabelText("recipient")).toHaveValue("a@b.c")

    fireEvent.change(screen.getByLabelText("Duration"), { target: { value: "permanent" } })
    fireEvent.click(screen.getByRole("button", { name: "Review rule" }))

    await waitFor(() => expect(calls.some((call) => call.path.endsWith("/preview"))).toBe(true))
    const body = calls.find((call) => call.path.endsWith("/preview"))!.body as { draft: Record<string, unknown> }
    expect(body.draft.constraints).toEqual({})
    expect(body.draft.duration).toBe("permanent")
  })
})
