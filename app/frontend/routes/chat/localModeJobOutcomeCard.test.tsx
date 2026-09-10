import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { LocalModeJobOutcomeCard, localModeJobOutcomeSummary, parseLocalModeJobOutcome } from "./localModeJobOutcomeCard"

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
      message: "opened"
    })!

    render(<LocalModeJobOutcomeCard result={result} />)

    expect(screen.getByText("JOB-325")).toBeInTheDocument()
    expect(screen.getByText("coding")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("syrus/direct-325")).toBeInTheDocument()
    expect(screen.getByText("opened")).toBeInTheDocument()
  })
})
