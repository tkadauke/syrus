import { jsonResponse } from "@app/testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MuseConnect } from "./MuseConnect"
import type { CredentialTestResult } from "@app/api/credentials"

function renderConnect(props: { onConnected?: (result: CredentialTestResult) => void; secondaryAction?: React.ReactNode } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MuseConnect onConnected={props.onConnected ?? (() => {})} secondaryAction={props.secondaryAction} />
    </QueryClientProvider>
  )
}

const museValid: CredentialTestResult = { credential: "muse_api_key", ok: true, message: "Muse API key is valid.", details: {} }

function mockRoutes(routes: { patch?: () => Response; test?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/credentials") && method === "PATCH") return routes.patch?.() ?? jsonResponse({})
    if (url.endsWith("/test_credential")) return routes.test?.() ?? jsonResponse({ credential_test: museValid })
    throw new Error(`unexpected fetch: ${method} ${url}`)
  })
}

describe("MuseConnect", () => {
  afterEach(() => vi.restoreAllMocks())

  it("saves and validates the API key through the Connect button, calling onConnected on success", async () => {
    const fetchSpy = mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    const save = screen.getByRole("button", { name: "Connect" })
    expect(save).toBeDisabled()

    fireEvent.change(screen.getByLabelText("Muse API key"), { target: { value: "LLM|abc123" } })
    fireEvent.click(save)

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(museValid))
    const patchCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/credentials"))
    expect(JSON.parse(patchCall?.[1]?.body as string)).toEqual({ user: { muse_api_key: "LLM|abc123" } })
  })

  it("auto-connects when a key is pasted", async () => {
    mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.paste(screen.getByLabelText("Muse API key"), {
      clipboardData: { getData: () => "  LLM|pasted-key  " }
    })

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(museValid))
  })

  it("surfaces a failed validation without calling onConnected", async () => {
    mockRoutes({ test: () => jsonResponse({ credential_test: { credential: "muse_api_key", ok: false, message: "Meta rejected this key.", details: {} } }) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByLabelText("Muse API key"), { target: { value: "LLM|bad" } })
    fireEvent.click(screen.getByRole("button", { name: "Connect" }))

    await waitFor(() => expect(screen.getByText("Meta rejected this key.")).toBeInTheDocument())
    expect(onConnected).not.toHaveBeenCalled()
  })

  it("renders the host-provided secondary action", () => {
    mockRoutes()
    renderConnect({ secondaryAction: <button type="button">Cancel</button> })

    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
  })
})
