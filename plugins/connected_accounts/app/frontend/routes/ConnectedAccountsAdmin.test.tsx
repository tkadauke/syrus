import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import ConnectedAccountsAdmin from "./ConnectedAccountsAdmin"

vi.mock("@app/hooks/useT", () => ({
  useT: () => ({
    t: translate,
    i18n: { t: translate }
  })
}))

function translate(key: string, options?: { defaultValue?: string }) {
  return (
    (
      {
        "settings.title": "Connected accounts",
        "settings.description": "Configure OAuth.",
        "settings.provider": "Provider",
        "example_workspace:settings.provider_notice": "Register your own provider client and check current verification policy.",
        "settings.client_id": "Client ID",
        "settings.client_secret": "Client secret",
        "settings.client_secret_configured": "A client secret is configured. Enter a new value only to replace it.",
        "settings.save": "Save configuration",
        "settings.saved": "Provider configuration saved.",
        "settings.save_failed": "Could not save provider configuration.",
        "settings.scope_catalog": "Scope catalog",
        "settings.read_only_scopes": "Read-only scopes",
        "settings.api_origins": "API origins",
        "instance.title": "Instance accounts",
        "instance.description": "Connect a provider token.",
        "instance.label": "Safe account label",
        "instance.token": "Provider token",
        "instance.connect": "Connect token",
        "instance.rotate": "Rotate token",
        "instance.disconnect": "Disconnect",
        "instance.status": "Status"
      } satisfies Record<string, string>
    )[key] ??
    options?.defaultValue ??
    key
  )
}

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
    const config = {
      authorize_url: "https://oauth.example/authorize",
      scope_catalog: ["profile", "write"],
      read_only_scopes: ["profile"],
      api_origins: ["https://api.example/"]
    }
    vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse({ providers: [{ ...config, provider_key: "generic_oauth2", display_name: "Generic OAuth 2", managed_settings: false }] })
      )
      .mockResolvedValueOnce(jsonResponse({ error: { code: "validation_failed", message: "Provider URLs must use HTTPS" } }, 422))

    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: "Save configuration" }))

    expect(await screen.findByText("Provider URLs must use HTTPS")).toBeInTheDocument()
  })

  it("keeps batched scope edits in the saved configuration", async () => {
    const config = { authorize_url: "https://oauth.example/authorize", scope_catalog: [], read_only_scopes: [], api_origins: [] }
    const fetchMock = vi
      .spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse({ providers: [{ ...config, provider_key: "generic_oauth2", display_name: "Generic OAuth 2", managed_settings: false }] })
      )
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
    expect(JSON.parse(String(request?.body))).toMatchObject({
      provider_config: {
        scope_catalog: ["profile", "calendar.write"],
        read_only_scopes: ["profile"],
        api_origins: ["https://api.example/"]
      }
    })
  })

  it("shows only instance credentials and provider-owned policy copy for a managed provider", async () => {
    vi.spyOn(window, "fetch").mockResolvedValueOnce(
      jsonResponse({
        providers: [
          {
            provider_key: "example_workspace",
            plugin_name: "example_workspace",
            display_name: "Example",
            managed_settings: true,
            client_secret_configured: true,
            settings_notice: "Fallback provider notice.",
            settings_notice_i18n_key: "example_workspace:settings.provider_notice"
          }
        ]
      })
    )

    renderPage()
    expect(await screen.findByText(/check current verification policy/)).toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "Client ID" })).toBeInTheDocument()
    expect(screen.getByLabelText("Client secret")).toHaveAttribute("type", "password")
    expect(screen.queryByRole("textbox", { name: "Authorization URL" })).not.toBeInTheDocument()
  })

  it("clears a submitted client secret after saving it", async () => {
    const provider = {
      provider_key: "example_workspace",
      plugin_name: "example_workspace",
      display_name: "Example",
      managed_settings: true,
      client_secret_configured: false
    }
    vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse({ providers: [provider] }))
      .mockResolvedValueOnce(jsonResponse({ provider_config: { ...provider, client_secret_configured: true } }))

    renderPage()
    const secret = await screen.findByLabelText("Client secret")
    fireEvent.change(secret, { target: { value: "submitted-secret" } })
    expect(secret).toHaveValue("submitted-secret")

    fireEvent.click(screen.getByRole("button", { name: "Save configuration" }))

    expect(await screen.findByText("Provider configuration saved.")).toBeInTheDocument()
    expect(secret).toHaveValue("")
    expect(screen.getByText(/client secret is configured/)).toBeInTheDocument()
  })

  it("submits an instance token once and clears the secret field", async () => {
    const fetchMock = vi
      .spyOn(window, "fetch")
      .mockResolvedValueOnce(
        jsonResponse({ providers: [{ provider_key: "delivery", display_name: "Delivery", managed_settings: true, authorization_kind: "token" }] })
      )
      .mockResolvedValueOnce(jsonResponse({ accounts: [], providers: [{ key: "delivery", display_name: "Delivery" }] }))
      .mockResolvedValueOnce(jsonResponse({ account: { id: 1, provider: "delivery", display_label: "Bot", status: "connected" } }, 201))
      .mockResolvedValueOnce(
        jsonResponse({
          accounts: [{ id: 1, provider: "delivery", display_label: "Bot", status: "connected" }],
          providers: [{ key: "delivery", display_name: "Delivery" }]
        })
      )

    renderPage()
    const token = await screen.findByLabelText("Provider token")
    fireEvent.change(token, { target: { value: "one-time-secret" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect token" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(4))
    expect(JSON.parse(String(fetchMock.mock.calls[2]?.[1]?.body))).toMatchObject({ account: { provider: "delivery", token: "one-time-secret" } })
    expect(token).toHaveValue("")
  })
})
