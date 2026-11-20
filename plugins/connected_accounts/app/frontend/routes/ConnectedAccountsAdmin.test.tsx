import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
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
      "settings.save_failed": "Could not save provider configuration.",
      "settings.scope_catalog": "Scope catalog",
      "settings.read_only_scopes": "Read-only scopes",
      "settings.api_origins": "API origins"
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

  it("keeps batched scope edits in the saved configuration", async () => {
    const config = { authorize_url: "https://oauth.example/authorize", scope_catalog: [],
      read_only_scopes: [], api_origins: [] }
    const fetchMock = vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse({ provider_config: config }))
      .mockResolvedValueOnce(jsonResponse({ provider_config: config }))

    renderPage()
    const scopeCatalog = await screen.findByRole("textbox", { name: "Scope catalog" })
    const readOnlyScopes = screen.getByRole("textbox", { name: "Read-only scopes" })
    const apiOrigins = screen.getByRole("textbox", { name: "API origins" })

    act(() => {
      fireEvent.change(scopeCatalog, { target: { value: "profile, calendar.write" } })
      fireEvent.change(readOnlyScopes, { target: { value: "profile" } })
      fireEvent.change(apiOrigins, { target: { value: "https://api.example/" } })
    })
    fireEvent.click(screen.getByRole("button", { name: "Save configuration" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(2))
    const request = fetchMock.mock.calls[1]?.[1]
    expect(JSON.parse(String(request?.body))).toMatchObject({ provider_config: {
      scope_catalog: [ "profile", "calendar.write" ],
      read_only_scopes: [ "profile" ],
      api_origins: [ "https://api.example/" ]
    } })
  })
})
