import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { CredentialStoreAdmin } from "./CredentialStoreAdmin"
import type { CredentialStorePayload } from "../api/credentialStore"

describe("CredentialStoreAdmin", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    window.localStorage.clear()
  })

  it("frames the normal credential page without an admin eyebrow", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />, "/credential_store")

    expect(await screen.findByRole("heading", { name: "Credential Store" })).toBeInTheDocument()
    expect(screen.queryByText("Admin")).not.toBeInTheDocument()
  })

  it("renders safe metadata and opens write-only edit fields without exposing secret payloads", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      credentials: [
        credential({
          name: "Deploy token",
          safe_metadata: { host: "github.com", username: "deploy-bot" }
        })
      ]
    })))

    renderRoute(<CredentialStoreAdmin />)

    expect(await screen.findByText("Deploy token")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(within(screen.getByRole("menu")).getByLabelText("Safe metadata"))
    expect(screen.getAllByText(/github.com/).length).toBeGreaterThan(0)
    expect(screen.queryByText("super-secret-token")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Edit" }))

    const dialog = screen.getByRole("dialog", { name: "Edit credential" })
    const payloadField = within(dialog).getByLabelText("Payload") as HTMLTextAreaElement
    expect(payloadField.value).toBe("")
    expect(payloadField).toHaveAttribute("autocomplete", "new-password")
    expect(screen.queryByDisplayValue("super-secret-token")).not.toBeInTheDocument()
  })

  it("opens a create modal, saves the draft, and closes after success", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/credentials") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(payload({
          credentials: [credential({ name: "CI token", safe_metadata: { host: "ci.example.com" } })]
        })))
      }
      return Promise.resolve(jsonResponse(payload({ credentials: [] })))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    const dialog = screen.getByRole("dialog", { name: "New credential" })
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "CI token" } })
    fireEvent.change(within(dialog).getByLabelText("Credential type"), { target: { value: "credential_store.generic" } })
    fireEvent.change(within(dialog).getByLabelText("Scope target"), { target: { value: "1" } })
    fireEvent.change(within(dialog).getByLabelText("Payload"), { target: { value: "super-secret-token" } })
    fireEvent.change(within(dialog).getByLabelText("Safe metadata"), { target: { value: '{"host":"ci.example.com"}' } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create credential" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credential_store/credentials", expect.objectContaining({ method: "POST" })))
    expect(requestCredential(fetchSpy, "/api/v1/app/credential_store/credentials", "POST")).toEqual(expect.objectContaining({
      name: "CI token",
      payload: "super-secret-token",
      safe_metadata: { host: "ci.example.com" }
    }))
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "New credential" })).not.toBeInTheDocument())
    expect(await screen.findByText("CI token")).toBeInTheDocument()
    expect(screen.queryByText("super-secret-token")).not.toBeInTheDocument()
  })

  it("submits edit metadata without sending a blank payload", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/credentials/1") && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(payload({
          credentials: [credential({ safe_metadata: { host: "git.example.com" } })]
        })))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "Edit" }))
    const dialog = screen.getByRole("dialog", { name: "Edit credential" })
    fireEvent.change(within(dialog).getByLabelText("Safe metadata"), { target: { value: '{"host":"git.example.com"}' } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Save changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/credential_store/credentials/1", expect.objectContaining({ method: "PATCH" })))
    const body = requestCredential(fetchSpy, "/api/v1/app/credential_store/credentials/1", "PATCH")
    expect(body).not.toHaveProperty("payload")
    expect(body.safe_metadata).toEqual({ host: "git.example.com" })
    fireEvent.click(screen.getByRole("button", { name: "Columns" }))
    fireEvent.click(within(screen.getByRole("menu")).getByLabelText("Safe metadata"))
    expect(await screen.findByText(/git.example.com/)).toBeInTheDocument()
  })

  it("cancels create and edit modals without submitting", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    fireEvent.change(within(screen.getByRole("dialog", { name: "New credential" })).getByLabelText("Name"), { target: { value: "Do not save" } })
    fireEvent.click(within(screen.getByRole("dialog", { name: "New credential" })).getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "New credential" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Edit" }))
    fireEvent.click(within(screen.getByRole("dialog", { name: "Edit credential" })).getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "Edit credential" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("shows enabled plugin credential types and omits disabled plugin type names", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      options: {
        credential_types: [
          { name: "credential_store.generic", label: "Generic secret", plugin: "credential_store" },
          { name: "k8s_cluster.kubeconfig", label: "Kubernetes kubeconfig", plugin: "k8s_cluster" }
        ]
      }
    })))

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    const typeSelect = screen.getByLabelText("Credential type")
    expect(within(typeSelect).getByRole("option", { name: /credential_store\.generic/ })).toBeInTheDocument()
    expect(within(typeSelect).getByRole("option", { name: /k8s_cluster\.kubeconfig/ })).toBeInTheDocument()
  })

  it("keeps disabled-plugin type names out of the type selector", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    const typeSelect = screen.getByLabelText("Credential type")
    expect(within(typeSelect).getByRole("option", { name: /credential_store\.generic/ })).toBeInTheDocument()
    expect(within(typeSelect).queryByRole("option", { name: /k8s_cluster\.kubeconfig/ })).not.toBeInTheDocument()
  })

  it("shows local JSON validation errors without submitting", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    const dialog = screen.getByRole("dialog", { name: "New credential" })
    fireEvent.change(within(dialog).getByLabelText("Safe metadata"), { target: { value: "{" } })
    fireEvent.change(within(dialog).getByLabelText("Target constraints"), { target: { value: "[]" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create credential" }))

    expect(await within(dialog).findByText("Safe metadata must be valid JSON.")).toBeInTheDocument()
    expect(within(dialog).getByText("Target constraints must be a JSON object.")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledTimes(1)
  })

  it("clears stale save API errors when the credential modal is reopened", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/credentials") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ error: { message: "Name has already been taken." } }, 422))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "New credential" }))
    let dialog = screen.getByRole("dialog", { name: "New credential" })
    fireEvent.change(within(dialog).getByLabelText("Name"), { target: { value: "Deploy token" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create credential" }))

    expect(await within(dialog).findByText("Name has already been taken.")).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "New credential" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "New credential" }))
    dialog = screen.getByRole("dialog", { name: "New credential" })
    expect(within(dialog).queryByText("Name has already been taken.")).not.toBeInTheDocument()
  })

  it("surfaces disabled-plugin API errors", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      error: { code: "plugin_disabled", message: "Credential Store is disabled." }
    }, 404))

    renderRoute(<CredentialStoreAdmin />)

    expect(await screen.findByText("Credential Store is disabled.")).toBeInTheDocument()
  })

  it("rotates with a write-only payload from a modal and closes after success", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/1/rotate") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(payload({
          credentials: [ credential({ last_rotated_at: "2026-10-02T12:30:00Z" }) ]
        })))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "Rotate" }))
    const dialog = screen.getByRole("dialog", { name: "Rotate Deploy token" })
    const rotateInput = within(dialog).getByLabelText("New payload for Deploy token") as HTMLTextAreaElement
    fireEvent.change(rotateInput, { target: { value: "new-secret" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Rotate" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credential_store/credentials/1/rotate",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ credential: { payload: "new-secret" } })
        })
      )
    })
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Rotate Deploy token" })).not.toBeInTheDocument())
    expect(screen.queryByText("new-secret")).not.toBeInTheDocument()
  })

  it("keeps the rotate modal open and surfaces API errors", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/1/rotate") && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ error: { message: "Payload is too short." } }, 422))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "Rotate" }))
    const dialog = screen.getByRole("dialog", { name: "Rotate Deploy token" })
    fireEvent.change(within(dialog).getByLabelText("New payload for Deploy token"), { target: { value: "x" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Rotate" }))

    expect(await within(dialog).findByText("Payload is too short.")).toBeInTheDocument()
    expect(screen.getByRole("dialog", { name: "Rotate Deploy token" })).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "Rotate Deploy token" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Rotate" }))
    const reopenedDialog = screen.getByRole("dialog", { name: "Rotate Deploy token" })
    expect(within(reopenedDialog).queryByText("Payload is too short.")).not.toBeInTheDocument()
  })

  it("renders revocation state after revoke succeeds", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path.endsWith("/1/revoke") && init?.method === "POST") {
        return Promise.resolve(jsonResponse(payload({
          credentials: [ credential({ revoked_at: "2026-10-02T12:00:00Z", active: false }) ]
        })))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "Revoke" }))

    expect(await screen.findByText("Revoked")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Revoke" })).toBeDisabled()
  })

  it("renders the default desktop data table columns", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    expect(await screen.findByRole("columnheader", { name: "Name" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Credential type" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Scope" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Target" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Status" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Last used" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Last rotated" })).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Expires" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Columns" })).toBeInTheDocument()
  })

  it("offers a visible text filter in the shared FilterBar", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    fireEvent.click(await screen.findByRole("button", { name: "+ Add filter" }))

    expect(screen.getByRole("button", { name: "Text text" })).toBeInTheDocument()
  })

  it("filters credentials from the shared FilterBar q parameter", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      credentials: [
        credential({ id: 1, name: "Deploy token", revoked_at: null, active: true }),
        credential({ id: 2, name: "Legacy token", revoked_at: "2026-10-02T12:00:00Z", active: false })
      ]
    })))

    renderRoute(<CredentialStoreAdmin />, `/admin/credential_store?q=${encodeFilter({ and: [{ field: "status", op: "is", value: "revoked" }] })}`)

    expect(await screen.findByText("Legacy token")).toBeInTheDocument()
    expect(screen.queryByText("Deploy token")).not.toBeInTheDocument()
  })

  it("sorts the desktop table through sortable column headers", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload({
      credentials: [
        credential({ id: 1, name: "Beta token" }),
        credential({ id: 2, name: "Alpha token" })
      ]
    })))

    renderRoute(<CredentialStoreAdmin />)

    expect(await credentialRowNames()).toEqual(["Alpha token", "Beta token"])
    fireEvent.click(screen.getByRole("button", { name: /Name/ }))
    expect(await credentialRowNames()).toEqual(["Beta token", "Alpha token"])
  })

  it("uses the fixed mobile credential list without column configuration", async () => {
    mockViewport("mobile")
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    expect(await screen.findByText("Deploy token")).toBeInTheDocument()
    expect(screen.queryByRole("table")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Columns" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Rotate" })).toBeInTheDocument()
  })
})

async function credentialRowNames() {
  const table = await screen.findByRole("table")
  return within(table).getAllByRole("row").slice(1).map((row) => within(row).getByText(/token$/).textContent)
}

function renderRoute(children: ReactNode, initialEntry = "/admin/credential_store") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[initialEntry]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function encodeFilter(filter: Record<string, unknown>) {
  return window.btoa(unescape(encodeURIComponent(JSON.stringify(filter)))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function requestCredential(fetchSpy: { mock: { calls: Array<[unknown, RequestInit?]> } }, path: string, method: string) {
  const call = fetchSpy.mock.calls.find(([input, init]) => String(input) === path && init?.method === method)
  expect(call).toBeTruthy()
  return JSON.parse(String(call?.[1]?.body)).credential as Record<string, unknown>
}

function mockViewport(viewport: "desktop" | "mobile") {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    value: vi.fn().mockImplementation((query: string) => {
      const matches = viewport === "mobile" ? query.includes("max-width") : query.includes("min-width")
      return {
        matches,
        media: query,
        onchange: null,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        addListener: vi.fn(),
        removeListener: vi.fn(),
        dispatchEvent: vi.fn()
      }
    })
  })
}

function payload(overrides: Partial<Omit<CredentialStorePayload, "options">> & { options?: Partial<CredentialStorePayload["options"]> } = {}): CredentialStorePayload {
  const base: CredentialStorePayload = {
    credentials: [ credential() ],
    options: {
      credential_types: [
        { name: "credential_store.generic", label: "Generic secret", plugin: "credential_store" }
      ],
      scopes: [
        { value: "user", label: "User" },
        { value: "repository", label: "Repository" },
        { value: "team", label: "Team" },
        { value: "instance", label: "Instance" }
      ],
      safe_metadata_keys: [ "host", "username", "fingerprint", "cluster", "context", "base_url" ],
      target_constraint_keys: [ "allowed_hosts", "allowed_kube_contexts", "allowed_url_prefixes" ],
      users: [ { id: 1, label: "Operator", detail: "operator@example.com" } ],
      repositories: [ { id: 10, label: "acme/widgets" } ],
      teams: [ { id: 20, label: "Deployers" } ]
    }
  }
  return {
    ...base,
    ...overrides,
    options: { ...base.options, ...overrides.options }
  }
}

function credential(overrides: Partial<CredentialStorePayload["credentials"][number]> = {}): CredentialStorePayload["credentials"][number] {
  return {
    id: 1,
    name: "Deploy token",
    description: null,
    credential_type: "credential_store.generic",
    scope_type: "user",
    scope_id: 1,
    scope_label: "Operator",
    safe_metadata: { host: "github.com" },
    target_constraints: { allowed_hosts: [ "github.com" ] },
    allowed_surfaces: [ "workflow" ],
    allowed_tools: [ "git.push" ],
    expires_at: null,
    last_rotated_at: "2026-10-02T12:00:00Z",
    revoked_at: null,
    active: true,
    can_manage: true,
    created_by: { id: 1, display_name: "Operator", email_address: "operator@example.com" },
    owner_user: { id: 1, display_name: "Operator", email_address: "operator@example.com" },
    last_access: null,
    created_at: "2026-10-02T11:00:00Z",
    updated_at: "2026-10-02T12:00:00Z",
    ...overrides
  }
}
