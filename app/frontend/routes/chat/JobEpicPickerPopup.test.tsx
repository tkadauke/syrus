import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi, beforeEach } from "vitest"
import { JobEpicPickerPopup } from "./JobEpicPickerPopup"
import * as jobsApi from "../../api/jobs"
import * as epicsApi from "../../api/epics"

function makeQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

function renderPicker(props: React.ComponentProps<typeof JobEpicPickerPopup>) {
  const queryClient = makeQueryClient()
  return render(
    <QueryClientProvider client={queryClient}>
      <JobEpicPickerPopup {...props} />
    </QueryClientProvider>
  )
}

const sampleJobs = {
  count: 2,
  jobs: [
    { id: 101, title: "Fix authentication bug", issue_title: "Fix authentication bug", state: "open", repository_slug: "acme/repo" },
    { id: 202, title: "Add dark mode", issue_title: "Add dark mode", state: "open", repository_slug: "acme/repo" }
  ]
}

const sampleEpics = {
  count: 2,
  epics: [
    { id: 5, number: 5, title: "API redesign", state: "in_progress", repository_slug: "acme/repo" },
    { id: 8, number: 8, title: "Mobile launch", state: "ready", repository_slug: "acme/repo" }
  ]
}

describe("JobEpicPickerPopup — jobs mode", () => {
  beforeEach(() => {
    vi.spyOn(jobsApi, "fetchPickerJobs").mockResolvedValue(sampleJobs)
  })

  it("renders a search input and job list", async () => {
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    expect(await screen.findByText("Fix authentication bug")).toBeInTheDocument()
    expect(screen.getByText("Add dark mode")).toBeInTheDocument()
    expect(screen.getByText("JOB-101")).toBeInTheDocument()
    expect(screen.getByText("JOB-202")).toBeInTheDocument()
  })

  it("filters items by title substring", async () => {
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "dark" } })

    expect(screen.getByText("Add dark mode")).toBeInTheDocument()
    expect(screen.queryByText("Fix authentication bug")).not.toBeInTheDocument()
  })

  it("filters items by ID", async () => {
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "101" } })

    expect(screen.getByText("Fix authentication bug")).toBeInTheDocument()
    expect(screen.queryByText("Add dark mode")).not.toBeInTheDocument()
  })

  it("calls onSelect with the job id string when a row is clicked", async () => {
    const onSelect = vi.fn()
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect, onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    fireEvent.click(screen.getByRole("option", { name: /JOB-101/ }))

    expect(onSelect).toHaveBeenCalledWith("101")
  })

  it("calls onSelect with the active job id on Enter", async () => {
    const onSelect = vi.fn()
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect, onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    fireEvent.keyDown(screen.getByRole("combobox"), { key: "Enter" })

    expect(onSelect).toHaveBeenCalledWith("101")
  })

  it("moves the active index down on ArrowDown", async () => {
    const onSelect = vi.fn()
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect, onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    const input = screen.getByRole("combobox")
    fireEvent.keyDown(input, { key: "ArrowDown" })
    fireEvent.keyDown(input, { key: "Enter" })

    expect(onSelect).toHaveBeenCalledWith("202")
  })

  it("calls onCancel on Escape", async () => {
    const onCancel = vi.fn()
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel })

    await screen.findByText("Fix authentication bug")
    fireEvent.keyDown(screen.getByRole("combobox"), { key: "Escape" })

    expect(onCancel).toHaveBeenCalled()
  })

  it("shows empty state when query matches nothing", async () => {
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    await screen.findByText("Fix authentication bug")
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "zzznomatch" } })

    expect(screen.getByText("No jobs found.")).toBeInTheDocument()
  })

  it("passes the repositorySlug to the API", async () => {
    renderPicker({ kind: "job", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    await waitFor(() => {
      expect(jobsApi.fetchPickerJobs).toHaveBeenCalledWith(
        expect.objectContaining({ repo: "acme/repo", state: "open" })
      )
    })
  })

  it("works without a repository slug", async () => {
    renderPicker({ kind: "job", repositorySlug: null, onSelect: vi.fn(), onCancel: vi.fn() })

    await waitFor(() => {
      expect(jobsApi.fetchPickerJobs).toHaveBeenCalledWith(
        expect.objectContaining({ repo: undefined, state: "open" })
      )
    })
  })
})

describe("JobEpicPickerPopup — epics mode", () => {
  beforeEach(() => {
    vi.spyOn(epicsApi, "fetchPickerEpics").mockResolvedValue(sampleEpics)
  })

  it("renders a search input and epic list", async () => {
    renderPicker({ kind: "epic", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    expect(await screen.findByText("API redesign")).toBeInTheDocument()
    expect(screen.getByText("Mobile launch")).toBeInTheDocument()
    expect(screen.getByText("EPIC-5")).toBeInTheDocument()
    expect(screen.getByText("EPIC-8")).toBeInTheDocument()
  })

  it("calls onSelect with the epic id string when a row is clicked", async () => {
    const onSelect = vi.fn()
    renderPicker({ kind: "epic", repositorySlug: "acme/repo", onSelect, onCancel: vi.fn() })

    await screen.findByText("API redesign")
    fireEvent.click(screen.getByRole("option", { name: /EPIC-5/ }))

    expect(onSelect).toHaveBeenCalledWith("5")
  })

  it("shows empty state when query matches nothing", async () => {
    renderPicker({ kind: "epic", repositorySlug: "acme/repo", onSelect: vi.fn(), onCancel: vi.fn() })

    await screen.findByText("API redesign")
    fireEvent.change(screen.getByRole("combobox"), { target: { value: "zzznomatch" } })

    expect(screen.getByText("No epics found.")).toBeInTheDocument()
  })
})
