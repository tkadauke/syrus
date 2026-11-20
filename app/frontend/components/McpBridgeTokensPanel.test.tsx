import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { McpBridgeTokensPanel } from "./McpBridgeTokensPanel"

const laptop = {
  id: 7,
  name: "laptop",
  token_prefix: "syrus_mcp_abc123",
  chat_id: 12,
  last_used_at: null,
  revoked_at: null,
  created_at: "2026-11-19T10:00:00Z"
}

function renderPanel() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <McpBridgeTokensPanel />
    </QueryClientProvider>
  )
}

describe("McpBridgeTokensPanel", () => {
  afterEach(() => vi.restoreAllMocks())

  it("issues a token and shows its plaintext once, with the registration command", async () => {
    const tokens = [] as (typeof laptop)[]
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      if (init?.method === "POST") {
        tokens.push(laptop)
        return jsonResponse({ token: laptop, plaintext: "syrus_mcp_secret", endpoint: "https://syrus.example/mcp/bridge" }, 201)
      }
      return jsonResponse({ tokens })
    })
    renderPanel()

    expect(await screen.findByText("No MCP bridge tokens.")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Token name"), { target: { value: "laptop" } })
    fireEvent.click(screen.getByRole("button", { name: "Create token" }))

    expect(await screen.findByText("syrus_mcp_secret")).toBeInTheDocument()
    expect(
      screen.getByText(
        'claude mcp add --transport http syrus https://syrus.example/mcp/bridge --header "Authorization: Bearer syrus_mcp_secret"'
      )
    ).toBeInTheDocument()
    const post = fetchSpy.mock.calls.find(([, init]) => init?.method === "POST")
    expect(JSON.parse(String(post?.[1]?.body))).toEqual({ name: "laptop" })
    await waitFor(() => expect(screen.getByText("laptop")).toBeInTheDocument())
  })

  it("lists active tokens without their plaintext and revokes after confirmation", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      if (init?.method === "DELETE") return jsonResponse({ token: { ...laptop, revoked_at: "2026-11-19T11:00:00Z" } })
      return jsonResponse({ tokens: [laptop, { ...laptop, id: 8, name: "old", revoked_at: "2026-11-01T00:00:00Z" }] })
    })
    renderPanel()

    const panel = await screen.findByTestId("mcp-bridge-tokens")
    expect(await within(panel).findByText("laptop")).toBeInTheDocument()
    expect(within(panel).queryByText("old")).not.toBeInTheDocument()
    expect(within(panel).getByText("never used")).toBeInTheDocument()

    fireEvent.click(within(panel).getByRole("button", { name: "Revoke" }))
    const dialog = await screen.findByRole("dialog")
    fireEvent.click(within(dialog).getByRole("button", { name: "Confirm" }))

    await waitFor(() =>
      expect(fetchSpy.mock.calls.some(([url, init]) => String(url).endsWith("/mcp_bridge_tokens/7") && init?.method === "DELETE")).toBe(true)
    )
  })
})
