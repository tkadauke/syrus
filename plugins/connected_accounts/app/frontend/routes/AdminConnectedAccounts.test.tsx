import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AdminConnectedAccounts } from "./AdminConnectedAccounts"

describe("AdminConnectedAccounts", () => {
  afterEach(() => vi.restoreAllMocks())

  it("lists providers and submits client secrets only in the create request", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "POST") return Promise.resolve(jsonResponse({ provider: { id: 2 } }, 201))
      return Promise.resolve(jsonResponse({ providers: [ { id: 1, key: "example", display_name: "Example", authorize_url: "https://oauth.example/authorize", token_url: "https://oauth.example/token", revoke_url: null, identity_url: null, scopes: [ "read" ], api_origins: [ "https://api.example/" ] } ] }))
    })
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(<QueryClientProvider client={client}><MemoryRouter><AdminConnectedAccounts /></MemoryRouter></QueryClientProvider>)

    expect(await screen.findByText("Example")).toBeInTheDocument()
    const values: Record<string, string> = {
      "Stable key": "new_provider", "Display name": "New provider", "Authorize URL": "https://new.example/authorize",
      "Token URL": "https://new.example/token", "Client ID": "client-id", "Client secret": "client-secret",
      "Scopes (space-separated)": "read write", "Allowed API origins": "https://api.new.example/"
    }
    Object.entries(values).forEach(([label, value]) => fireEvent.change(screen.getByLabelText(label), { target: { value } }))
    fireEvent.click(screen.getByRole("button", { name: "Create provider" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/connected_account_providers", expect.objectContaining({ method: "POST" })))
    const createCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "POST")
    expect(JSON.parse(String(createCall?.[1]?.body))).toMatchObject({ client_id: "client-id", client_secret: "client-secret", scopes: [ "read", "write" ] })
    expect(document.body.textContent).not.toContain("client-secret")
  })
})
