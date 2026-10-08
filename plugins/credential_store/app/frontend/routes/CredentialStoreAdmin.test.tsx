import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import { CredentialStoreAdmin } from "./CredentialStoreAdmin"
import type { CredentialStorePayload } from "../api/credentialStore"

describe("CredentialStoreAdmin", () => {
  it("frames the normal credential page without an admin eyebrow", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />, "/credential_store")

    expect(await screen.findByRole("heading", { name: "Credential Store" })).toBeInTheDocument()
    expect(screen.queryByText("Admin")).not.toBeInTheDocument()
  })

  it("renders safe metadata and write-only fields without exposing secret payloads", async () => {
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
    expect(screen.getAllByText(/github.com/).length).toBeGreaterThan(0)
    expect(screen.queryByText("super-secret-token")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Edit" }))

    const payloadField = screen.getByLabelText("Payload") as HTMLTextAreaElement
    expect(payloadField.value).toBe("")
    expect(payloadField).toHaveAttribute("autocomplete", "new-password")
    expect(screen.queryByDisplayValue("super-secret-token")).not.toBeInTheDocument()
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

    const typeSelect = await screen.findByLabelText("Credential type")
    expect(within(typeSelect).getByRole("option", { name: /credential_store\.generic/ })).toBeInTheDocument()
    expect(within(typeSelect).getByRole("option", { name: /k8s_cluster\.kubeconfig/ })).toBeInTheDocument()
  })

  it("keeps disabled-plugin type names out of the type selector", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))

    renderRoute(<CredentialStoreAdmin />)

    const typeSelect = await screen.findByLabelText("Credential type")
    expect(within(typeSelect).getByRole("option", { name: /credential_store\.generic/ })).toBeInTheDocument()
    expect(within(typeSelect).queryByRole("option", { name: /k8s_cluster\.kubeconfig/ })).not.toBeInTheDocument()
  })

  it("surfaces disabled-plugin API errors", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      error: { code: "plugin_disabled", message: "Credential Store is disabled." }
    }, 404))

    renderRoute(<CredentialStoreAdmin />)

    expect(await screen.findByText("Credential Store is disabled.")).toBeInTheDocument()
  })

  it("rotates with a write-only payload and clears the field after success", async () => {
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

    const rotateInput = await screen.findByLabelText("New payload for Deploy token") as HTMLInputElement
    fireEvent.change(rotateInput, { target: { value: "new-secret" } })
    fireEvent.click(screen.getByRole("button", { name: "Rotate" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/credential_store/credentials/1/rotate",
        expect.objectContaining({
          method: "POST",
          body: JSON.stringify({ credential: { payload: "new-secret" } })
        })
      )
    })
    await waitFor(() => expect(rotateInput.value).toBe(""))
    expect(screen.queryByText("new-secret")).not.toBeInTheDocument()
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
})

function renderRoute(children: ReactNode, path = "/admin/credential_store") {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
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
