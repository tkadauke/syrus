import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import ConnectedAccountsAdmin from "./ConnectedAccountsAdmin"

vi.mock("@app/hooks/useT", () => ({
  useT: () => ({
    t: (key: string) => ({
      "settings.title": "Connected accounts",
      "settings.description": "Configure OAuth.",
      "settings.save": "Save configuration",
      "settings.saved": "Provider configuration saved.",
      "settings.save_failed": "Could not save provider configuration."
    } satisfies Record<string, string>)[key] ?? key
  })
}))

function renderPage() {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })}>
      <ConnectedAccountsAdmin />
    </QueryClientProvider>
  )
}

afterEach(() => vi.restoreAllMocks())

describe("ConnectedAccountsAdmin", () => {
  it("shows the API error when provider configuration cannot be saved", async () => {
    const config = { authorize_url: "https://oauth.example/authorize", scope_catalog: [ "profile", "write" ],
      read_only_scopes: [ "profile" ], api_origins: [ "https://api.example/" ] }
    vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse({ provider_config: config }))
      .mockResolvedValueOnce(jsonResponse({ error: { code: "validation_failed", message: "Provider URLs must use HTTPS" } }, 422))

    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: "Save configuration" }))

    expect(await screen.findByText("Provider URLs must use HTTPS")).toBeInTheDocument()
  })
})
