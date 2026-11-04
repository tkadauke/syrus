import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { AdminPermissionModel } from "./AdminPermissionModel"
import * as resetApi from "../api/adminPermissionFactoryReset"

vi.mock("../api/adminPermissionFactoryReset", async (importOriginal) => {
  const actual = await importOriginal<typeof resetApi>()
  return { ...actual, previewPermissionFactoryReset: vi.fn(), applyPermissionFactoryReset: vi.fn() }
})

const preview = {
  scope_type: "instance" as const,
  scope_id: null,
  default_version: "permissions-factory@v1",
  counts: {
    rules: 3,
    leases: 2,
    authorized_invocations: 1,
    pending_requests: 1,
    resumptions: 1,
    profile_selections: 2,
    factory_rules_to_create: 4,
    factory_presets_to_create: 0
  },
  confirmation_digest: "digest",
  retained_data: ["audit_history", "users", "repositories", "jobs", "workflows", "permission_reset_audits"],
  instance_confirmation: "RESET INSTANCE"
}

function renderPage() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter>
        <AdminPermissionModel />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminPermissionModel", () => {
  beforeEach(() => vi.resetAllMocks())

  it("requires preview and typed confirmation before applying an instance reset", async () => {
    vi.mocked(resetApi.previewPermissionFactoryReset).mockResolvedValue(preview)
    vi.mocked(resetApi.applyPermissionFactoryReset).mockResolvedValue({
      outcome: "succeeded",
      changed: true,
      counts: preview.counts,
      audit: { id: 42, completed_at: "2026-11-04T12:00:00Z", default_version: preview.default_version }
    })
    renderPage()

    fireEvent.change(screen.getByLabelText("Scope"), { target: { value: "instance" } })
    expect(screen.queryByLabelText("Scope identifier")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Preview reset" }))

    expect(await screen.findByRole("heading", { name: "Destructive reset preview" })).toBeInTheDocument()
    expect(screen.getByLabelText("Exact reset counts")).toHaveTextContent("Active rules to revoke3")
    expect(screen.getByText("Permission rule and lease audit history")).toBeInTheDocument()
    const apply = screen.getByRole("button", { name: "Apply factory reset" })
    expect(apply).toBeDisabled()

    fireEvent.change(screen.getByLabelText("Type RESET INSTANCE to enable the instance-wide reset"), { target: { value: "RESET INSTANCE" } })
    expect(apply).toBeEnabled()
    fireEvent.click(apply)

    await waitFor(() => expect(resetApi.applyPermissionFactoryReset).toHaveBeenCalledWith(preview, "RESET INSTANCE"))
    expect(await screen.findByRole("status")).toHaveTextContent("Factory reset completed. Audit record #42.")
  })

  it("labels every supported scope and disables preview until a required id is supplied", () => {
    renderPage()

    const scope = screen.getByLabelText("Scope")
    expect(scope).toHaveAccessibleName("Scope")
    expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual(["Chat", "Actor (Global ID)", "User", "Repository", "Whole instance"])
    expect(screen.getByRole("button", { name: "Preview reset" })).toBeDisabled()
    fireEvent.change(screen.getByLabelText("Scope identifier"), { target: { value: "17" } })
    expect(screen.getByRole("button", { name: "Preview reset" })).toBeEnabled()
  })
})
