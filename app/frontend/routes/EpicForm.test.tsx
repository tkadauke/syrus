import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import type { EpicFormPayload } from "../api/epics"
import { EpicForm } from "./EpicForm"

function formPayload(overrides: Partial<EpicFormPayload["epic"]> = {}): EpicFormPayload {
  return {
    epic: {
      id: null,
      title: "Raise the forum",
      description: "Install tasteful columns.",
      owner_user_id: null,
      owner_status: "unclaimed",
      owner_user: null,
      repository_id: 1,
      github_issue_url: "",
      epic_path: null,
      ...overrides
    },
    repositories: [{ id: 1, slug: "acme/widgets" }],
    dashboard_epics_path: "/dashboard/epics"
  }
}

function renderForm(mode: "new" | "edit", payload = formPayload()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <EpicForm mode={mode} payload={payload} prefix="" />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

describe("EpicForm create buttons", () => {
  afterEach(() => vi.restoreAllMocks())

  it("submits create-and-start with the start flag", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "Epic created and started — child Jobs will dispatch as they are added.", redirect_to: "/epics/3", epic: formPayload().epic })
    )
    renderForm("new")

    fireEvent.click(screen.getByRole("button", { name: "Create Epic & Start Implementing" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/epics")
    expect(init?.method).toBe("POST")
    expect(JSON.parse(init?.body as string)).toMatchObject({ start: true, epic: { title: "Raise the forum" } })
  })

  it("submits a plain create without the start flag", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "Epic created.", redirect_to: "/epics/3", epic: formPayload().epic })
    )
    renderForm("new")

    fireEvent.click(screen.getByRole("button", { name: "Create Epic" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [, init] = fetchSpy.mock.calls[0]
    expect(JSON.parse(init?.body as string)).not.toHaveProperty("start")
  })

  it("plain-creates on implicit form submission (Enter key) — never create-and-start", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({ message: "Epic created.", redirect_to: "/epics/3", epic: formPayload().epic })
    )
    renderForm("new")

    // The start button must not be a submit button, so the form's default
    // (implicit Enter-key) submission can only ever plain-create.
    expect(screen.getByRole("button", { name: "Create Epic & Start Implementing" })).toHaveAttribute("type", "button")
    expect(screen.getByRole("button", { name: "Create Epic" })).toHaveAttribute("type", "submit")

    const form = screen.getByRole("button", { name: "Create Epic" }).closest("form")
    expect(form).not.toBeNull()
    fireEvent.submit(form as HTMLFormElement)

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    const [, init] = fetchSpy.mock.calls[0]
    expect(JSON.parse(init?.body as string)).not.toHaveProperty("start")
  })

  it("does not offer create-and-start in edit mode", () => {
    renderForm("edit", formPayload({ id: 3, epic_path: "/epics/3" }))

    expect(screen.queryByRole("button", { name: "Create Epic & Start Implementing" })).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Save Epic" })).toBeInTheDocument()
  })
})
