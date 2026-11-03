import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { ApiError } from "../api/client"
import type { SmartPermissionOption } from "../api/permissionRequests"
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
})
