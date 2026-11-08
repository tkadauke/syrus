import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ApiError } from "../api/client"
import type { SmartPermissionOption } from "../api/permissionRequests"
import { jsonResponse } from "../testSupport"
import { SmartPermissionActions } from "./SmartPermissionActions"

const option: SmartPermissionOption = {
  kind: "always_allow_similar",
  duration: "permanent",
  digest: "digest-1",
  summary: { allows: ["Maya may run mail.send/draft."], excludes: ["Other operations", "Anything a higher-layer rule denies"] },
  draft: {},
  ceiling: {},
  context: { coworker: "Maya", operation: "mail.send/draft", repository: null, resource_scope_label: "Drafts folder", duration: "permanent" }
}
const chatOption: SmartPermissionOption = {
  ...option,
  kind: "allow_chat",
  duration: "chat_session",
  digest: "digest-chat",
  context: { ...option.context, duration: "chat_session" }
}

function setup(props: Partial<React.ComponentProps<typeof SmartPermissionActions>> = {}) {
  const handlers = { onAllowOnce: vi.fn(), onDeny: vi.fn(), onConfirm: vi.fn(), onStale: vi.fn() }
  render(
    <MemoryRouter>
      <SmartPermissionActions busy={false} error={null} option={option} {...handlers} {...props} />
    </MemoryRouter>
  )
  return handlers
}

describe("SmartPermissionActions", () => {
  it("keeps the default footprint to three decisions", () => {
    setup()
    expect(screen.getAllByRole("button").map((button) => button.textContent)).toEqual(["Allow once", "Always allow similar", "Deny"])
  })

  it("presents chat-scoped and permanent choices separately", () => {
    const handlers = setup({ options: [chatOption, option] })

    expect(screen.getAllByRole("button").map((button) => button.textContent)).toEqual(["Allow once", "Allow for this chat", "Always allow similar", "Deny"])
    fireEvent.click(screen.getByRole("button", { name: "Allow for this chat" }))
    expect(screen.getByText("This chat only")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))
    expect(handlers.onConfirm).toHaveBeenCalledWith(chatOption)
  })

  it("offers only Allow once and Deny without an adaptive option", () => {
    setup({ option: null })
    expect(screen.getAllByRole("button").map((button) => button.textContent)).toEqual(["Allow once", "Deny"])
  })

  it("previews exact coworker, operation, scope, duration and exclusions before confirming", () => {
    const handlers = setup()
    fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))

    const preview = screen.getByRole("group", { name: "Always allow similar" })
    expect(preview).toHaveTextContent("Maya")
    expect(preview).toHaveTextContent("mail.send/draft")
    expect(preview).toHaveTextContent("Drafts folder")
    expect(preview).toHaveTextContent("Permanent until you revoke it")
    expect(preview).toHaveTextContent("Anything a higher-layer rule denies")
    expect(screen.getByRole("link", { name: "Customize" })).toHaveAttribute("href", "/settings/permissions")
    expect(handlers.onConfirm).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))
    expect(handlers.onConfirm).toHaveBeenCalledWith(option)
  })

  it("moves focus into the preview and returns it on Back and Escape", async () => {
    setup()
    fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))
    expect(screen.getByRole("heading", { name: "Always allow similar" })).toHaveFocus()

    fireEvent.click(screen.getByRole("button", { name: "Back" }))
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    await vi.waitFor(() => expect(screen.getByRole("button", { name: "Always allow similar" })).toHaveFocus())

    fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))
    fireEvent.keyDown(screen.getByRole("group", { name: "Always allow similar" }), { key: "Escape" })
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
  })

  it("disables every decision while applying and marks the preview busy", () => {
    setup({ busy: true })
    expect(screen.getAllByRole("button").every((button) => button.hasAttribute("disabled"))).toBe(true)
  })

  it("returns to the actions and asks the parent to reload when the preview is stale", () => {
    const stale = new ApiError("stale", { status: 409, code: "stale_permission_decision" })
    const handlers = setup({ error: stale })
    expect(handlers.onStale).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("alert")).toHaveTextContent("changed since the preview")
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
  })

  it("announces other failures", () => {
    setup({ error: new ApiError("Ceiling exceeded", { status: 422 }) })
    expect(screen.getByRole("alert")).toHaveTextContent("Ceiling exceeded")
  })

  it("routes Allow once and Deny to their handlers", () => {
    const handlers = setup()
    fireEvent.click(screen.getByRole("button", { name: "Allow once" }))
    fireEvent.click(screen.getByRole("button", { name: "Deny" }))
    expect(handlers.onAllowOnce).toHaveBeenCalledTimes(1)
    expect(handlers.onDeny).toHaveBeenCalledTimes(1)
  })

  describe("Customize with the exact pending call", () => {
    afterEach(() => vi.restoreAllMocks())

    const editorOptions = {
      capability: "mail.send@v1",
      operation: "mail.send/draft@v1",
      policies: ["allow", "deny"],
      risk: "medium",
      subject_types: [{ type: "agent", requires_id: true, requires_repository: false, roles: ["chat:planner"], exact_agent: true }],
      resource_scope: { type: "none", options: null },
      constraint_fields: {},
      authority_durations: ["chat_session", "job", "permanent"],
      maximum_autonomy: "permanent",
      maximum_duration_seconds: null,
      permanent_allowed: true,
      ceilings: []
    }
    const editorPreview = {
      valid: true,
      errors: [],
      warnings: [],
      digest: "custom-digest",
      draft: {
        policy: "allow",
        duration: "permanent",
        role: "chat:planner",
        subject: { type: "agent", id: "12", subject_type: "Coworkers::Coworker", repository_id: null },
        capability: "mail.send@v1",
        operation: "mail.send/draft@v1",
        resource_scope: {},
        resource_scope_label: "",
        constraints: {},
        chat_session_id: null,
        job_id: null,
        expires_at: null,
        rationale: null
      },
      summary: { allows: ["Allows coworker 12 to run mail.send/draft@v1."], excludes: ["Excludes every other operation and capability."] },
      ceiling: { maximum_autonomy: "permanent", maximum_duration_seconds: null, permanent_allowed: true, limited_by: null },
      examples: { matches: ["coworker 12 running mail.send/draft@v1."], non_matches: ["Anyone other than coworker 12."] }
    }

    function setupCustomize() {
      const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
        const path = String(input)
        if (path.includes("/options")) return Promise.resolve(jsonResponse({ options: editorOptions }))
        if (path.endsWith("/from_request") || path.endsWith("/preview")) return Promise.resolve(jsonResponse({ preview: editorPreview }))
        return Promise.resolve(jsonResponse({ authority: { kind: "PermissionRule", id: 3, capability: "mail.send@v1", operation: null } }, 201))
      })
      const onCustomized = vi.fn()
      render(
        <MemoryRouter>
          <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
            <SmartPermissionActions
              busy={false}
              error={null}
              onAllowOnce={vi.fn()}
              onConfirm={vi.fn()}
              onCustomized={onCustomized}
              onDeny={vi.fn()}
              option={option}
              request={{ requestId: 5, itemId: 6 }}
            />
          </QueryClientProvider>
        </MemoryRouter>
      )
      return { fetchSpy, onCustomized }
    }

    it("keeps the compact row and opens the editor in an accessible dialog prefilled from the request", async () => {
      const { fetchSpy } = setupCustomize()
      expect(screen.getAllByRole("button").map((button) => button.textContent)).toEqual(["Allow once", "Always allow similar", "Deny"])

      fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))
      fireEvent.click(screen.getByRole("button", { name: "Customize" }))

      const dialog = await screen.findByRole("dialog", { name: "Customize permission rule" })
      expect(await within(dialog).findByLabelText("Applies to")).toHaveValue("agent")
      const call = fetchSpy.mock.calls.find(([path]) => String(path).endsWith("/from_request"))!
      expect(JSON.parse(String(call[1]?.body))).toMatchObject({ request_id: 5, item_id: 6, duration: "permanent" })
    })

    it("saves the customized rule and then decides the pending call", async () => {
      const { onCustomized } = setupCustomize()
      fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))
      fireEvent.click(screen.getByRole("button", { name: "Customize" }))
      await screen.findByLabelText("Applies to")

      // The prefilled draft already carries the server preview for the exact call.
      fireEvent.click(await screen.findByRole("button", { name: "Save rule" }))

      await waitFor(() => expect(onCustomized).toHaveBeenCalledWith("approved"))
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    })

    it("returns focus to Customize when the dialog is cancelled", async () => {
      setupCustomize()
      fireEvent.click(screen.getByRole("button", { name: "Always allow similar" }))
      fireEvent.click(screen.getByRole("button", { name: "Customize" }))
      await screen.findByLabelText("Applies to")

      fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

      await waitFor(() => expect(screen.getByRole("button", { name: "Customize" })).toHaveFocus())
    })
  })
})

// An operator who does not want to approve every `git commit ...` separately
// edits the proposed prefix in the card. Confirming an edited prefix has to
// fetch the digest for *that* prefix: the rule being written is not the one
// the card previewed, and the server rejects a digest that does not match.
describe("SmartPermissionActions prefix editing", () => {
  const prefixOption: SmartPermissionOption = {
    ...option,
    kind: "always_allow_command",
    prefix: { field: "command_prefix", value: "git commit", full: "git commit -m hello" }
  }
  const request = { requestId: 7, itemId: 9 }

  afterEach(() => vi.restoreAllMocks())

  function openPreview(props: Partial<React.ComponentProps<typeof SmartPermissionActions>> = {}) {
    const handlers = { onAllowOnce: vi.fn(), onDeny: vi.fn(), onConfirm: vi.fn(), onStale: vi.fn() }
    render(
      <MemoryRouter>
        <QueryClientProvider client={new QueryClient()}>
          <SmartPermissionActions busy={false} error={null} option={prefixOption} request={request} {...handlers} {...props} />
        </QueryClientProvider>
      </MemoryRouter>
    )
    fireEvent.click(screen.getByRole("button", { name: "Always allow this command" }))
    return handlers
  }

  it("offers the suggested prefix for editing and shows the call it came from", () => {
    openPreview()
    expect(screen.getByLabelText("Allow commands starting with")).toHaveValue("git commit")
    expect(screen.getByTestId("smart-permission-prefix").textContent).toContain("git commit -m hello")
  })

  it("confirms an untouched suggestion with the digest already in hand", () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")
    const handlers = openPreview()

    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    expect(handlers.onConfirm).toHaveBeenCalledWith(expect.objectContaining({ digest: "digest-1" }))
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("re-previews an edited prefix so the digest matches the rule being written", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({ preview: { valid: true, errors: [], warnings: [], digest: "digest-widened", draft: {}, summary: {}, ceiling: {} } })
    )
    const handlers = openPreview()

    fireEvent.change(screen.getByLabelText("Allow commands starting with"), { target: { value: "git" } })
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() =>
      expect(handlers.onConfirm).toHaveBeenCalledWith(
        expect.objectContaining({ digest: "digest-widened", prefix: expect.objectContaining({ value: "git" }) })
      )
    )
  })

  it("refuses a prefix the server will not grant rather than sending it anyway", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({ preview: { valid: false, errors: [{ code: "constraint_invalid_value", message: "That prefix is not allowed." }], warnings: [], digest: null, draft: {}, summary: {}, ceiling: {} } })
    )
    const handlers = openPreview()

    fireEvent.change(screen.getByLabelText("Allow commands starting with"), { target: { value: "x" } })
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))

    await waitFor(() => expect(screen.getByRole("alert").textContent).toContain("That prefix is not allowed."))
    expect(handlers.onConfirm).not.toHaveBeenCalled()
  })

  it("will not confirm an empty prefix, which would widen without limit", () => {
    openPreview()
    fireEvent.change(screen.getByLabelText("Allow commands starting with"), { target: { value: "   " } })
    expect(screen.getByRole("button", { name: "Confirm" })).toBeDisabled()
  })
})
