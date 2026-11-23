import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import ConnectedAccountsSettings from "./ConnectedAccountsSettings"

vi.mock("@app/hooks/useT", () => ({
  useT: () => ({ t: (key: string, values?: Record<string, string>) => (values?.provider ? `Connect ${values.provider}` : key) })
}))

function renderPage() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })}>
      <ConnectedAccountsSettings />
    </QueryClientProvider>
  )
}

afterEach(() => vi.restoreAllMocks())

describe("ConnectedAccountsSettings", () => {
  it("shows account status, scopes, last use, and all management actions", async () => {
    vi.spyOn(window, "fetch").mockResolvedValueOnce(
      jsonResponse({
        accounts: [
          {
            id: 7,
            provider: "mail",
            display_label: "person@example.com",
            status: "connected",
            granted_scopes: ["mail.read"],
            read_only: false,
            acting_modes: ["as_self"],
            last_used_at: null,
            reauthorize_url: "/reauthorize"
          }
        ],
        providers: [{ key: "mail", display_name: "Mail", scopes: ["mail.read"], supports_read_only: true }]
      })
    )

    renderPage()

    expect(await screen.findByText("person@example.com")).toBeInTheDocument()
    expect(screen.getByText("accounts.scopes")).toBeInTheDocument()
    expect(screen.getByText("accounts.last_used")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "accounts.reauthorize" })).toHaveAttribute("href", "/reauthorize")
    expect(screen.getByRole("button", { name: "accounts.disconnect" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Connect Mail" })).toHaveAttribute(
      "href",
      "/api/v1/app/connected_accounts/connect/mail?scopes=mail.read&read_only=true"
    )
  })

  it("persists the read-only toggle", async () => {
    const fetchMock = vi
      .spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse({
          accounts: [
            {
              id: 7,
              provider: "mail",
              display_label: "person@example.com",
              status: "connected",
              granted_scopes: ["mail.read"],
              read_only: false,
              acting_modes: ["as_self"],
              last_used_at: null,
              reauthorize_url: "/reauthorize"
            }
          ],
          providers: []
        })
      )
      .mockResolvedValueOnce(jsonResponse({ account: { id: 7, read_only: true } }))
      .mockResolvedValueOnce(jsonResponse({ accounts: [], providers: [] }))

    renderPage()
    fireEvent.click(await screen.findByRole("checkbox", { name: "accounts.read_only" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(3))
    expect(JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body))).toEqual({ account: { read_only: true } })
  })
})
