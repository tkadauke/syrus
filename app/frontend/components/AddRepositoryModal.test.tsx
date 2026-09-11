import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { AddRepositoryModal } from "./AddRepositoryModal"

function renderModal(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AddRepositoryModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

const newFormPayload = {
  repository: {
    id: null,
    owner: "",
    name: "",
    slug: null,
    default_branch: "main",
    upstream_owner: "",
    upstream_name: "",
    upstream_default_branch: "",
    trigger_label: "syrus",
    polling_enabled: true,
    prepare_enabled: true,
    pr_cost_footer_enabled: true,
    auto_merge_enabled: false,
    trust_clean_rebase_grade: false,
    agent_provider: "",
    auto_approve_mode: "never",
    github_owner_id: null,
    github_repository_id: null,
    repository_path: null
  },
  configured_agent_providers: [{ value: "claude", label: "Claude" }],
  user_agent_provider_label: "Claude",
  auto_approve_modes: [],
  repositories_path: "/repositories"
}

function mockRoutes(over: { owners?: () => Response; create?: () => Response; detail?: () => Response; repos?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = String(input)
    if (url.includes("/repositories/new")) return jsonResponse(newFormPayload)
    if (url.includes("/repositories/owners")) return over.owners?.() ?? jsonResponse({ user: "octocat", orgs: ["acme"] })
    if (url.includes("/repositories/repos"))
      return over.repos?.() ?? jsonResponse({ repos: [{ name: "hello-world", github_repository_id: 7, github_owner_id: 3 }] })
    if (url.includes("/repositories/branches")) return jsonResponse({ branches: ["main", "dev"], default_branch: "main" })
    if (url.endsWith("/admin/github_app/sync_installations")) return jsonResponse({ enqueued: true })
    if (/\/api\/v1\/app\/repositories\/\d+$/.test(url) && init?.method !== "POST") {
      return over.detail?.() ?? jsonResponse({ credential_status: credentialStatus("pat") })
    }
    if (url.endsWith("/api/v1/app/repositories") && init?.method === "POST") {
      return over.create?.() ?? jsonResponse({ message: "Saved", redirect_to: "/repositories/1", repository: {} })
    }
    throw new Error(`unexpected fetch: ${url}`)
  })
}

function credentialStatus(mode: "app" | "pat") {
  return {
    mode,
    label: mode === "app" ? "GitHub App active" : "PAT fallback: no active App installation",
    installation_account: mode === "app" ? "octocat" : null,
    github_app_registered: true,
    install_url: mode === "pat" ? "https://github.com/apps/operator-syrus/installations/new?suggested_target_id=3" : null,
    generic_install_url: mode === "pat" ? "https://github.com/apps/operator-syrus/installations/new" : null,
    register_path: null,
    previous_installation_removed: false,
    missing_github_ids: false
  }
}

const savedRepository = { id: 1, slug: "octocat/hello-world", owner: "octocat", name: "hello-world" }

async function submitRepository() {
  fireEvent.change(await screen.findByRole("combobox", { name: "User/Org" }), { target: { value: "octocat" } })
  fireEvent.change(await screen.findByRole("combobox", { name: "Repository" }), { target: { value: "hello-world" } })
  fireEvent.click(screen.getByRole("button", { name: "Add repository" }))
}

describe("AddRepositoryModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows only the User/Org dropdown first and defaults the syrus label silently", async () => {
    mockRoutes()
    renderModal()

    const owner = (await screen.findByRole("combobox", { name: "User/Org" })) as HTMLSelectElement
    expect(Array.from(owner.options).map((o) => o.value)).toEqual(["", "octocat", "acme"])
    // Repository and branch fields are hidden until a User/Org is picked.
    expect(screen.queryByRole("combobox", { name: "Repository" })).not.toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Default branch" })).not.toBeInTheDocument()
    // No manual entry, no trigger-label field; the label defaults to syrus.
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument()
    expect(screen.getByText("syrus")).toBeInTheDocument()
    expect(screen.getByText(/add more later/i)).toBeInTheDocument()
  })

  it("reveals the Repository dropdown after a User/Org is selected, then a branch dropdown", async () => {
    mockRoutes()
    renderModal()

    fireEvent.change(await screen.findByRole("combobox", { name: "User/Org" }), { target: { value: "octocat" } })

    const repo = (await screen.findByRole("combobox", { name: "Repository" })) as HTMLSelectElement
    expect(Array.from(repo.options).map((o) => o.value)).toEqual(["", "hello-world"])
    fireEvent.change(repo, { target: { value: "hello-world" } })

    const branch = (await screen.findByRole("combobox", { name: "Default branch" })) as HTMLSelectElement
    expect(Array.from(branch.options).map((o) => o.value)).toEqual(["main", "dev"])
    expect(branch.value).toBe("main")
  })

  it("creates one repository with auto-merge on, inherited agent, and no upstream", async () => {
    const fetchSpy = mockRoutes()
    const onSaved = vi.fn()
    const onClose = vi.fn()
    renderModal({ onSaved, onClose })

    const owner = await screen.findByRole("combobox", { name: "User/Org" })
    fireEvent.change(owner, { target: { value: "octocat" } })

    const name = await screen.findByRole("combobox", { name: "Repository" })
    fireEvent.change(name, { target: { value: "hello-world" } })

    fireEvent.click(screen.getByRole("button", { name: "Add repository" }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(onSaved).toHaveBeenCalledTimes(1)

    const createCall = fetchSpy.mock.calls.find(([u, i]) => String(u).endsWith("/api/v1/app/repositories") && (i as RequestInit)?.method === "POST")
    const repo = JSON.parse((createCall?.[1] as RequestInit).body as string).repository
    expect(repo).toMatchObject({
      owner: "octocat",
      name: "hello-world",
      default_branch: "main",
      trigger_label: "syrus",
      auto_merge_enabled: true,
      agent_provider: "",
      upstream_owner: "",
      upstream_name: "",
      github_repository_id: "7"
    })
  })

  it("re-offers the account-wide install alongside the pre-scoped one", async () => {
    mockRoutes({
      create: () =>
        jsonResponse({
          message: "Saved",
          redirect_to: "/repositories/1",
          repository: savedRepository,
          credential_status: credentialStatus("pat")
        })
    })
    const openSpy = vi.spyOn(window, "open").mockReturnValue({ opener: null } as unknown as Window)
    renderModal()

    await submitRepository()

    const allRepos = await screen.findByRole("button", { name: /install for all repositories/ })
    fireEvent.click(allRepos)
    expect(openSpy).toHaveBeenCalledWith("https://github.com/apps/operator-syrus/installations/new", "_blank")
    await waitFor(() => expect(screen.getByText(/Waiting for GitHub/)).toBeInTheDocument())
  })

  it("offers the pre-scoped App install after adding a PAT-fallback repository, and detects the install", async () => {
    mockRoutes({
      create: () =>
        jsonResponse({
          message: "Saved",
          redirect_to: "/repositories/1",
          repository: savedRepository,
          credential_status: credentialStatus("pat")
        }),
      detail: () => jsonResponse({ credential_status: credentialStatus("app") })
    })
    const opened = { opener: {} as unknown }
    const openSpy = vi.spyOn(window, "open").mockReturnValue(opened as Window)
    const onClose = vi.fn()
    renderModal({ onClose })

    await submitRepository()

    expect(await screen.findByText("octocat/hello-world is ready.")).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByText(/Optional: install the Syrus GitHub App/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Install on GitHub/ }))
    expect(openSpy).toHaveBeenCalledWith("https://github.com/apps/operator-syrus/installations/new?suggested_target_id=3", "_blank")

    // The install-watch poll sees the linked installation and flips the
    // panel to a green check without any user action.
    await waitFor(() => expect(screen.getByText(/Syrus App connected/)).toBeInTheDocument())
    expect(screen.queryByRole("button", { name: /Install on GitHub/ })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Done" }))
    expect(onClose).toHaveBeenCalled()
  })

  it("closes immediately when the owner's installation already covers the new repository", async () => {
    mockRoutes({
      create: () =>
        jsonResponse({
          message: "Saved",
          redirect_to: "/repositories/1",
          repository: savedRepository,
          credential_status: credentialStatus("app")
        })
    })
    const onSaved = vi.fn()
    const onClose = vi.fn()
    renderModal({ onSaved, onClose })

    await submitRepository()

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(onSaved).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/Optional: install the Syrus GitHub App/)).not.toBeInTheDocument()
  })

  it("pre-fills and shows editable upstream fields when the selected repository is a fork", async () => {
    const fetchSpy = mockRoutes({
      repos: () =>
        jsonResponse({
          repos: [
            { name: "hello-world", github_repository_id: 7, github_owner_id: 3, fork: true, parent_full_name: "tkadauke/syrus", parent_default_branch: "main" }
          ]
        })
    })
    renderModal()

    fireEvent.change(await screen.findByRole("combobox", { name: "User/Org" }), { target: { value: "octocat" } })
    fireEvent.change(await screen.findByRole("combobox", { name: "Repository" }), { target: { value: "hello-world" } })

    expect(await screen.findByText(/This repository is a fork of tkadauke\/syrus/)).toBeInTheDocument()
    const upstreamOwner = (await screen.findByRole("textbox", { name: "Upstream owner" })) as HTMLInputElement
    const upstreamName = screen.getByRole("textbox", { name: "Upstream name" }) as HTMLInputElement
    const upstreamBranch = screen.getByRole("textbox", { name: "Upstream default branch" }) as HTMLInputElement
    expect(upstreamOwner.value).toBe("tkadauke")
    expect(upstreamName.value).toBe("syrus")
    expect(upstreamBranch.value).toBe("main")

    fireEvent.click(screen.getByRole("button", { name: "Add repository" }))

    await waitFor(() => {
      const createCall = fetchSpy.mock.calls.find(([u, i]) => String(u).endsWith("/api/v1/app/repositories") && (i as RequestInit)?.method === "POST")
      expect(createCall).toBeDefined()
    })
    const createCall = fetchSpy.mock.calls.find(([u, i]) => String(u).endsWith("/api/v1/app/repositories") && (i as RequestInit)?.method === "POST")
    const repo = JSON.parse((createCall?.[1] as RequestInit).body as string).repository
    expect(repo).toMatchObject({
      upstream_owner: "tkadauke",
      upstream_name: "syrus",
      upstream_default_branch: "main"
    })
  })

  it("lets the user edit or clear detected upstream fields, and submits what they typed", async () => {
    const fetchSpy = mockRoutes({
      repos: () =>
        jsonResponse({
          repos: [
            { name: "hello-world", github_repository_id: 7, github_owner_id: 3, fork: true, parent_full_name: "tkadauke/syrus", parent_default_branch: "main" }
          ]
        })
    })
    renderModal()

    fireEvent.change(await screen.findByRole("combobox", { name: "User/Org" }), { target: { value: "octocat" } })
    fireEvent.change(await screen.findByRole("combobox", { name: "Repository" }), { target: { value: "hello-world" } })

    const upstreamOwner = await screen.findByRole("textbox", { name: "Upstream owner" })
    fireEvent.change(upstreamOwner, { target: { value: "someone-else" } })
    // Editing dismisses the detection note but keeps the fields visible/editable.
    expect(screen.queryByText(/This repository is a fork of/)).not.toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "Upstream name" })).toBeInTheDocument()

    const upstreamName = screen.getByRole("textbox", { name: "Upstream name" })
    fireEvent.change(upstreamName, { target: { value: "" } })

    fireEvent.click(screen.getByRole("button", { name: "Add repository" }))

    await waitFor(() => {
      const createCall = fetchSpy.mock.calls.find(([u, i]) => String(u).endsWith("/api/v1/app/repositories") && (i as RequestInit)?.method === "POST")
      expect(createCall).toBeDefined()
    })
    const createCall = fetchSpy.mock.calls.find(([u, i]) => String(u).endsWith("/api/v1/app/repositories") && (i as RequestInit)?.method === "POST")
    const repo = JSON.parse((createCall?.[1] as RequestInit).body as string).repository
    expect(repo).toMatchObject({
      upstream_owner: "someone-else",
      upstream_name: ""
    })
  })

  it("leaves upstream fields blank and hidden for a non-fork repository", async () => {
    mockRoutes()
    renderModal()

    fireEvent.change(await screen.findByRole("combobox", { name: "User/Org" }), { target: { value: "octocat" } })
    fireEvent.change(await screen.findByRole("combobox", { name: "Repository" }), { target: { value: "hello-world" } })

    await screen.findByRole("combobox", { name: "Default branch" })
    expect(screen.queryByRole("textbox", { name: "Upstream owner" })).not.toBeInTheDocument()
    expect(screen.queryByText(/is a fork of/)).not.toBeInTheDocument()
  })

  it("shows a notice (no manual entry) when GitHub owners can't be loaded", async () => {
    mockRoutes({ owners: () => jsonResponse({ error: "no_token" }) })
    renderModal()

    await waitFor(() => expect(screen.getByText(/No GitHub token configured/)).toBeInTheDocument())
    // No dropdown and no manual fallback — the operator fixes GitHub first.
    expect(screen.queryByRole("combobox", { name: "User/Org" })).not.toBeInTheDocument()
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Add repository" })).toBeDisabled()
  })
})
