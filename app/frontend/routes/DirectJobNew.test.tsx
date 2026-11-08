import { describe, it, expect, vi, afterEach, beforeEach } from "vitest"
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { jsonResponse } from "../testSupport"
import { DirectJobNewRoute } from "./DirectJobNew"
import type { DirectJobFormPayload } from "../api/directJobs"
import * as useConfirmModule from "../hooks/useConfirm"

const template1 = {
  id: "add-github-actions-ci",
  name: "Add GitHub Actions CI",
  description: "Add a CI workflow that runs tests."
}
const template1Prompt = "Add a GitHub Actions CI workflow."

const template2 = {
  id: "update-dependencies",
  name: "Update dependencies",
  description: "Update all packages to latest."
}
const template2Prompt = "Update all packages to their latest compatible versions."

function formPayload(overrides: Partial<DirectJobFormPayload> = {}): DirectJobFormPayload {
  return {
    repositories: [
      {
        id: 1,
        slug: "acme/widgets",
        repository_path: "/repositories/1",
        default_agent_provider: "claude",
        default_agent_provider_label: "Claude"
      }
    ],
    selected_repository_id: "1",
    selected_agent_provider: null,
    selected_model: null,
    selected_effort_level: null,
    selected_epic_id: null,
    epic: null,
    configured_agent_providers: [],
    provider_routing_options: { agent_providers: [], effort_levels: [] },
    priorities: [{ value: "medium", label: "Medium", description: "Default" }],
    prompt_templates: [template1, template2],
    accepted_file_content_types: ["image/*", "application/pdf"],
    new_repository_path: "/repositories/new",
    dashboard_jobs_path: "/",
    create_more: false,
    ...overrides
  }
}

function renderRoute(payload = formPayload(), fetchTemplate?: (id: string) => Promise<Response>) {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const path = typeof input === "string" ? input : input instanceof URL ? input.href : input.url
    if (path.endsWith(`/prompt_templates/${template1.id}`)) {
      if (fetchTemplate) return fetchTemplate(template1.id)
      return Promise.resolve(jsonResponse({ id: template1.id, prompt: template1Prompt }))
    }
    if (path.endsWith(`/prompt_templates/${template2.id}`)) {
      if (fetchTemplate) return fetchTemplate(template2.id)
      return Promise.resolve(jsonResponse({ id: template2.id, prompt: template2Prompt }))
    }
    return Promise.resolve(jsonResponse(payload))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <DirectJobNewRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
  return client
}

describe("DirectJobNew agent provider icon", () => {
  afterEach(() => vi.restoreAllMocks())

  it("preserves an unsaved prompt when the form payload refetches", async () => {
    const client = renderRoute()

    const prompt = await screen.findByRole("textbox", { name: "Prompt" })
    fireEvent.change(prompt, { target: { value: "Unsaved prompt" } })
    client.setQueryData(["direct_jobs", "new", ""], formPayload({ selected_repository_id: null }))

    await waitFor(() => expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue("Unsaved prompt"))
  })

  it("renders the selected provider's icon at the expected size", async () => {
    renderRoute(
      formPayload({
        selected_agent_provider: "claude",
        configured_agent_providers: [
          { value: "claude", label: "Claude" },
          { value: "codex", label: "Codex" }
        ]
      })
    )

    const select = await screen.findByRole("combobox", { name: "Agent" })
    const icon = select.parentElement?.querySelector('img[src="/plugin-icons/claude_agent.svg"]')
    expect(icon).toBeInTheDocument()
    expect(icon).toHaveClass("h-4", "w-4")
  })

  it("falls back to the repository's default provider icon when no explicit provider is selected", async () => {
    renderRoute(
      formPayload({
        selected_agent_provider: null,
        configured_agent_providers: [
          { value: "claude", label: "Claude" },
          { value: "codex", label: "Codex" }
        ]
      })
    )

    const select = await screen.findByRole("combobox", { name: "Agent" })
    const icon = select.parentElement?.querySelector('img[src="/plugin-icons/claude_agent.svg"]')
    expect(icon).toBeInTheDocument()
  })
})

describe("DirectJobNew epic linking", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows which epic the job will join when the form payload targets one", async () => {
    renderRoute(
      formPayload({
        selected_epic_id: "7",
        epic: { id: 7, display_number: "EPIC-7", title: "Ship the thing" }
      })
    )

    const link = await screen.findByRole("link", { name: "EPIC-7 · Ship the thing" })
    expect(link).toHaveAttribute("href", "/epics/7")
  })

  it("shows no epic note when the form payload targets no epic", async () => {
    renderRoute()

    await screen.findByRole("textbox", { name: "Title" })
    expect(screen.queryByText(/added to/)).not.toBeInTheDocument()
  })

  it("submits epic_id alongside the job when targeting an epic", async () => {
    let submittedBody: FormData | null = null
    vi.spyOn(window, "fetch").mockImplementation((_url, init) => {
      if (init?.method === "POST") {
        submittedBody = init.body as FormData
        return Promise.resolve(
          jsonResponse({
            message: "Direct job created.",
            create_more: false,
            redirect_to: "/jobs/99",
            job: {
              id: 99,
              title: "Ship the thing",
              state: "queued",
              repository: {
                id: 1,
                slug: "acme/widgets",
                repository_path: "/repositories/1",
                default_agent_provider: "claude",
                default_agent_provider_label: "Claude"
              },
              job_path: "/jobs/99"
            }
          })
        )
      }

      return Promise.resolve(
        jsonResponse(
          formPayload({
            selected_epic_id: "7",
            epic: { id: 7, display_number: "EPIC-7", title: "Ship the thing" }
          })
        )
      )
    })

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <DirectJobNewRoute />
        </MemoryRouter>
      </QueryClientProvider>
    )

    fireEvent.change(await screen.findByRole("textbox", { name: "Prompt" }), { target: { value: "Add a piece of the Epic." } })
    fireEvent.click(screen.getByRole("button", { name: "Create job" }))

    await waitFor(() => expect(submittedBody).not.toBeNull())
    expect(submittedBody!.get("epic_id")).toBe("7")
  })
})

describe("DirectJobNew template selection", () => {
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
  })

  afterEach(() => vi.restoreAllMocks())

  it("clicking a template sets both title and prompt", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))

    await waitFor(() => {
      expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue(template1.name)
      expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue(template1Prompt)
    })
  })

  it("clicking a second template updates both title and prompt when no manual edits were made", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    await waitFor(() => {
      expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue(template2.name)
      expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue(template2Prompt)
    })
  })

  it("does not prompt for confirmation when switching templates without manual edits", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    await waitFor(() => expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue(template2Prompt))
    expect(mockConfirm).not.toHaveBeenCalled()
  })

  it("prompts for confirmation when manually edited title exists before applying a template", async () => {
    renderRoute()

    await screen.findByRole("button", { name: /Add GitHub Actions CI/i })
    fireEvent.change(screen.getByRole("textbox", { name: "Title" }), { target: { value: "My custom title" } })
    fireEvent.click(screen.getByRole("button", { name: /Add GitHub Actions CI/i }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(
        expect.objectContaining({ message: "Are you sure you want to apply this template? All of your changes will be lost." })
      )
    })
  })

  it("prompts for confirmation when manually edited prompt exists before applying a template", async () => {
    renderRoute()

    await screen.findByRole("button", { name: /Add GitHub Actions CI/i })
    fireEvent.change(screen.getByRole("textbox", { name: "Prompt" }), { target: { value: "My custom prompt" } })
    fireEvent.click(screen.getByRole("button", { name: /Add GitHub Actions CI/i }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
  })

  it("does not apply template when user cancels confirmation", async () => {
    mockConfirm.mockResolvedValue(false)
    renderRoute()

    await screen.findByRole("button", { name: /Add GitHub Actions CI/i })
    fireEvent.change(screen.getByRole("textbox", { name: "Title" }), { target: { value: "My custom title" } })
    fireEvent.click(screen.getByRole("button", { name: /Add GitHub Actions CI/i }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
    expect((screen.getByRole("textbox", { name: "Title" }) as HTMLInputElement).value).toBe("My custom title")
  })

  it("prompts for confirmation when switching from one template to another after manual edits", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))

    const titleInput = screen.getByRole("textbox", { name: "Title" }) as HTMLInputElement
    fireEvent.change(titleInput, { target: { value: "Modified title" } })

    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
      expect(titleInput.value).toBe(template2.name)
    })
  })

  it("does not prompt when form is empty and template is applied for the first time", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))

    expect(mockConfirm).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue(template1.name))
  })

  it("ignores an older template response that arrives after a newer selection", async () => {
    const resolvers = new Map<string, (response: Response) => void>()
    renderRoute(formPayload(), (id) => new Promise((resolve) => resolvers.set(id, resolve)))

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    resolvers.get(template2.id)!(jsonResponse({ id: template2.id, prompt: template2Prompt }))
    await waitFor(() => expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue(template2Prompt))

    await act(async () => {
      resolvers.get(template1.id)!(jsonResponse({ id: template1.id, prompt: template1Prompt }))
      await Promise.resolve()
    })
    expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue(template2.name)
    expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue(template2Prompt)
  })

  it("does not overwrite prompt edits made while a template is loading", async () => {
    let resolveTemplate!: (response: Response) => void
    renderRoute(
      formPayload(),
      () =>
        new Promise((resolve) => {
          resolveTemplate = resolve
        })
    )

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.change(screen.getByRole("textbox", { name: "Prompt" }), { target: { value: "Keep my in-flight edit" } })
    await act(async () => {
      resolveTemplate(jsonResponse({ id: template1.id, prompt: template1Prompt }))
      await Promise.resolve()
    })

    expect(screen.getByRole("textbox", { name: "Title" })).toHaveValue("")
    expect(screen.getByRole("textbox", { name: "Prompt" })).toHaveValue("Keep my in-flight edit")
  })
})
