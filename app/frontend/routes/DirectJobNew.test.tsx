import { describe, it, expect, vi, afterEach, beforeEach } from "vitest"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { jsonResponse } from "../testSupport"
import { DirectJobNewRoute } from "./DirectJobNew"
import type { DirectJobFormPayload } from "../api/directJobs"
import * as useConfirmModule from "../hooks/useConfirm"

const template1 = {
  id: "add-github-actions-ci",
  name: "Add GitHub Actions CI",
  description: "Add a CI workflow that runs tests.",
  prompt: "Add a GitHub Actions CI workflow."
}

const template2 = {
  id: "update-dependencies",
  name: "Update dependencies",
  description: "Update all packages to latest.",
  prompt: "Update all packages to their latest compatible versions."
}

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
    configured_agent_providers: [],
    priorities: [{ value: "medium", label: "Medium", description: "Default" }],
    prompt_templates: [template1, template2],
    accepted_file_content_types: ["image/*", "application/pdf"],
    new_repository_path: "/repositories/new",
    dashboard_jobs_path: "/",
    create_more: false,
    ...overrides
  }
}

function renderRoute(payload = formPayload()) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <DirectJobNewRoute />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

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

    expect((screen.getByRole("textbox", { name: "Title" }) as HTMLInputElement).value).toBe(template1.name)
    expect((screen.getByRole("textbox", { name: "Prompt" }) as HTMLTextAreaElement).value).toBe(template1.prompt)
  })

  it("clicking a second template updates both title and prompt when no manual edits were made", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    expect((screen.getByRole("textbox", { name: "Title" }) as HTMLInputElement).value).toBe(template2.name)
    expect((screen.getByRole("textbox", { name: "Prompt" }) as HTMLTextAreaElement).value).toBe(template2.prompt)
  })

  it("does not prompt for confirmation when switching templates without manual edits", async () => {
    renderRoute()

    fireEvent.click(await screen.findByRole("button", { name: /Add GitHub Actions CI/i }))
    fireEvent.click(screen.getByRole("button", { name: /Update dependencies/i }))

    expect(mockConfirm).not.toHaveBeenCalled()
  })

  it("prompts for confirmation when manually edited title exists before applying a template", async () => {
    renderRoute()

    await screen.findByRole("button", { name: /Add GitHub Actions CI/i })
    fireEvent.change(screen.getByRole("textbox", { name: "Title" }), { target: { value: "My custom title" } })
    fireEvent.click(screen.getByRole("button", { name: /Add GitHub Actions CI/i }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ message: "Are you sure you want to apply this template? All of your changes will be lost." }))
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
    expect((screen.getByRole("textbox", { name: "Title" }) as HTMLInputElement).value).toBe(template1.name)
  })
})
