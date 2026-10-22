import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import {
  CreateCodingJobOutcomeCard,
  LocalModeJobOutcomeCard,
  createCodingJobRequest,
  localModeJobOutcomeSummary,
  parseLocalModeJobOutcome
} from "./localModeJobOutcomeCard"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "create_coding_job", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("parseLocalModeJobOutcome", () => {
  it("parses the full open_in_local_mode shape", () => {
    const result = parseLocalModeJobOutcome({
      job_id: 4225,
      job_state: "coding",
      branch_name: "syrus/direct-325",
      repository_slug: "tkadauke/syrus",
      message: "JOB-325 is now open for local implementation on branch `syrus/direct-325`."
    })

    expect(result).toEqual({
      jobId: "4225",
      jobState: "coding",
      branchName: "syrus/direct-325",
      repositorySlug: "tkadauke/syrus",
      message: "JOB-325 is now open for local implementation on branch `syrus/direct-325`."
    })
  })

  it("parses the minimal cancel_local_mode shape (no branch/repository)", () => {
    const result = parseLocalModeJobOutcome({ job_id: 4225, job_state: "implemented", message: "Local mode session cancelled." })
    expect(result?.branchName).toBeNull()
    expect(result?.repositorySlug).toBeNull()
  })

  it("returns null when job_id or job_state is missing", () => {
    expect(parseLocalModeJobOutcome({ job_state: "coding" })).toBeNull()
    expect(parseLocalModeJobOutcome({ job_id: 4225 })).toBeNull()
  })

  it("returns null for a non-object payload", () => {
    expect(parseLocalModeJobOutcome("not json")).toBeNull()
  })
})

describe("localModeJobOutcomeSummary", () => {
  it("prefers the tool's message", () => {
    const result = parseLocalModeJobOutcome({ job_id: 1, job_state: "coding", message: "custom message" })!
    expect(localModeJobOutcomeSummary(result)).toBe("custom message")
  })

  it("falls back to JOB-id (state) when no message", () => {
    const result = parseLocalModeJobOutcome({ job_id: 1, job_state: "coding" })!
    expect(localModeJobOutcomeSummary(result)).toBe("JOB-1 (coding)")
  })
})

describe("LocalModeJobOutcomeCard", () => {
  it("renders job id, state, repository, branch, and message", () => {
    const result = parseLocalModeJobOutcome({
      job_id: 4225,
      job_state: "coding",
      branch_name: "syrus/direct-325",
      repository_slug: "tkadauke/syrus",
      message: "opened on `syrus/direct-325`"
    })!

    render(<LocalModeJobOutcomeCard result={result} />)

    expect(screen.getByText("JOB-4225")).toBeInTheDocument()
    expect(screen.getByText("coding")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByTitle("syrus/direct-325")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-325", { selector: "code" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("button", { name: "Copy syrus/direct-325 to clipboard" })).toBeInTheDocument()
    expect(screen.getByTitle("syrus/direct-325")).toHaveClass("w-0", "flex-1", "whitespace-normal", "break-all")
    expect(screen.getByTitle("syrus/direct-325")).not.toHaveClass("sm:truncate")
  })
})

describe("CreateCodingJobOutcomeCard", () => {
  it("parses and renders the request alongside linked result entities and markdown", () => {
    const body = `Build a **responsive** card.\n\n${"Include all request context. ".repeat(60)}`
    const toolContext = context({
      input: { title: "Improve the coding card", body, repository_id: 12 },
      parsedResult: {
        job_id: 7589,
        job_state: "queued",
        repository_slug: "tkadauke/syrus",
        message: "Created **JOB-7589** successfully."
      }
    })

    expect(createCodingJobRequest(toolContext)).toEqual({ title: "Improve the coding card", body: body.trim(), repositoryId: "12" })
    render(<CreateCodingJobOutcomeCard context={toolContext} />)

    expect(screen.getByRole("heading", { name: "Improve the coding card" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/12")
    expect(screen.getByTitle("12")).toHaveTextContent("12")
    expect(screen.getByRole("link", { name: /JOB-7589/ })).toHaveAttribute("href", "/jobs/7589")
    expect(screen.getByText("responsive")).toBeInTheDocument()
    expect(screen.getByText("JOB-7589", { selector: "strong" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show more" }))
    expect(screen.getByRole("dialog", { name: "Description" })).toBeInTheDocument()
    expect(screen.getByText(/Include all request context/, { selector: "p" })).toBeInTheDocument()
  })

  it("keeps request context visible when creation fails", () => {
    render(
      <CreateCodingJobOutcomeCard
        context={context({
          input: { title: "Unavailable repository", body: "Create the **job** anyway.", repository_id: 99 },
          resultBody: "Repository is unavailable.",
          resultError: true
        })}
      />
    )

    expect(screen.getByRole("heading", { name: "Unavailable repository" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Repository 99" })).toHaveAttribute("href", "/repositories/99")
    expect(screen.getByText("job", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByText("Repository is unavailable.")).toBeInTheDocument()
  })
})
