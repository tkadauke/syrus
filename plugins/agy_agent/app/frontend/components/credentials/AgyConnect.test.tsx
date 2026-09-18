import { jsonResponse } from "@app/testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AgyConnect } from "./AgyConnect"
import type { CredentialTestResult } from "@app/api/credentials"

function renderConnect(props: { onConnected?: (result: CredentialTestResult) => void; secondaryAction?: React.ReactNode } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AgyConnect onConnected={props.onConnected ?? (() => {})} secondaryAction={props.secondaryAction} />
    </QueryClientProvider>
  )
}

const VALID_KEY = "test-gemini-api-key-1234567890"
const agyValid: CredentialTestResult = {
  credential: "agy",
  ok: true,
  message: "Antigravity accepted the shared Gemini API key.",
  details: { shared_credential: "gemini_api_key" }
}

function mockRoutes(routes: { patch?: () => Response; agyTest?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    const method = init?.method ?? "GET"
    if (url.endsWith("/credentials") && method === "PATCH") return routes.patch?.() ?? jsonResponse({})
    if (url.endsWith("/test_credential")) return routes.agyTest?.() ?? jsonResponse({ credential_test: agyValid })
    throw new Error(`unexpected fetch: ${method} ${url}`)
  })
}

describe("AgyConnect", () => {
  afterEach(() => vi.restoreAllMocks())

  it("validates the format, saves the shared key, and confirms through the agy probe", async () => {
    const fetchSpy = mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByPlaceholderText("Paste your Gemini API key here"), { target: { value: VALID_KEY } })
    fireEvent.click(screen.getByRole("button", { name: "Validate & save" }))

    await waitFor(() => expect(screen.getByTestId("agy-stage-format")).toHaveAttribute("data-status", "ok"))
    await waitFor(() => expect(screen.getByTestId("agy-stage-reach")).toHaveAttribute("data-status", "ok"))
    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(agyValid))

    const patchCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/credentials"))
    expect(JSON.parse(patchCall?.[1]?.body as string)).toEqual({ user: { gemini_api_key: VALID_KEY } })
    const agyTestCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/test_credential"))
    expect(JSON.parse(agyTestCall?.[1]?.body as string)).toEqual({ credential: "agy" })
  })

  it("rejects an obviously malformed key without making a network call", async () => {
    const fetchSpy = mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByPlaceholderText("Paste your Gemini API key here"), { target: { value: "short" } })
    fireEvent.click(screen.getByRole("button", { name: "Validate & save" }))

    await waitFor(() => expect(screen.getByTestId("agy-stage-format")).toHaveAttribute("data-status", "failed"))
    expect(onConnected).not.toHaveBeenCalled()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("surfaces an agy probe failure without calling onConnected", async () => {
    mockRoutes({ agyTest: () => jsonResponse({ credential_test: { credential: "agy", ok: false, message: "Antigravity rejected this key.", details: {} } }) })
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.change(screen.getByPlaceholderText("Paste your Gemini API key here"), { target: { value: VALID_KEY } })
    fireEvent.click(screen.getByRole("button", { name: "Validate & save" }))

    await waitFor(() => expect(screen.getByText("Antigravity rejected this key.")).toBeInTheDocument())
    expect(onConnected).not.toHaveBeenCalled()
  })

  it("auto-validates when a key is pasted", async () => {
    mockRoutes()
    const onConnected = vi.fn()
    renderConnect({ onConnected })

    fireEvent.paste(screen.getByPlaceholderText("Paste your Gemini API key here"), {
      clipboardData: { getData: () => `  ${VALID_KEY}  ` }
    })

    await waitFor(() => expect(onConnected).toHaveBeenCalledWith(agyValid))
  })

  it("renders the host-provided secondary action", () => {
    mockRoutes()
    renderConnect({ secondaryAction: <button type="button">Cancel</button> })

    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
  })
})
