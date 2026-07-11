import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { AdminInvitations } from "./AdminInvitations"

describe("AdminInvitations", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("copies the share URL to clipboard when the link is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(invitationsPayload())))

    renderRoute(<AdminInvitations />)

    const copyButton = await screen.findByRole("button", { name: "Copy signup link for foo@bar.com" }, { timeout: 5000 })
    act(() => { fireEvent.click(copyButton) })

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("https://example.com/users/new?token=abc123")
    expect(screen.getByText("Link copied to clipboard.")).toBeInTheDocument()
  })

  it("does not navigate when the share URL is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(invitationsPayload())))

    renderRoute(<AdminInvitations />)

    const copyButton = await screen.findByRole("button", { name: "Copy signup link for foo@bar.com" })
    expect(copyButton.tagName).toBe("BUTTON")
    expect(copyButton).not.toHaveAttribute("href")
  })

  it("shows the share URL text in the copy button", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(invitationsPayload())))

    renderRoute(<AdminInvitations />)

    expect(await screen.findByText("https://example.com/users/new?token=abc123")).toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function invitationsPayload() {
  return {
    invitations: [
      {
        id: 1,
        email_address: "foo@bar.com",
        token: "abc123",
        share_url: "https://example.com/users/new?token=abc123",
        expires_at: "2026-07-10T11:44:11.000Z",
        created_at: "2026-07-03T11:44:11.000Z",
        invited_by_email_address: "admin@example.com"
      }
    ]
  }
}
