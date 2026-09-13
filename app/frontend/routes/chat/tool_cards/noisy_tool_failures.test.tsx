import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import askUserQuestionToolCard from "./ask_user_question"
import attachRepositoryToolCard from "./attach_repository"
import proposeEpicWithJobsToolCard from "./propose_epic_with_jobs"
import proposeJobToolCard from "./propose_job"
import readPrToolCard from "./read_pr"
import repoInfoToolCard from "./repo_info"
import reopenJobToolCard from "./reopen_job"

const CARDS: ToolCardRenderer[] = [
  proposeEpicWithJobsToolCard,
  proposeJobToolCard,
  attachRepositoryToolCard,
  readPrToolCard,
  askUserQuestionToolCard,
  repoInfoToolCard,
  reopenJobToolCard
]

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    input: {},
    resultBody: "tool failed",
    resultError: true,
    parsedResult: { message: "tool failed" },
    ...overrides
  }
}

describe("noisy chat tool failure cards", () => {
  it("registers the requested core noisy tool names", () => {
    expect(CARDS.map((card) => card.toolName)).toEqual([
      "propose_epic_with_jobs",
      "propose_job",
      "attach_repository",
      "read_pr",
      "ask_user_question",
      "repo_info",
      "reopen_job"
    ])
  })

  it("renders proposal failures with the attempted proposal and affected IDs", () => {
    const toolContext = context("propose_job", {
      input: { title: "Fix noisy cards", target_epic_id: 349 },
      parsedResult: {
        error_class: "ActiveRecord::RecordInvalid",
        message: "Validation failed: title is too short",
        retryable: false
      }
    })

    expect(proposeJobToolCard.collapsedSummary?.(toolContext)).toBe(
      "Job proposal failed: Validation failed: title is too short"
    )

    render(<>{proposeJobToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("Job proposal failed")).toBeInTheDocument()
    expect(screen.getByText("Propose Job: Fix noisy cards")).toBeInTheDocument()
    expect(screen.getByText("Check before retrying")).toBeInTheDocument()
    expect(screen.getByText("EPIC-349")).toBeInTheDocument()
    expect(screen.getByText("Check whether a proposal card was created before retrying.")).toBeInTheDocument()
  })

  it("marks read-only failures as safe to retry and shows the PR identifier", () => {
    const toolContext = context("read_pr", {
      input: { pr_number: 72 },
      parsedResult: { error_class: "Octokit::NotFound", message: "Not found" }
    })

    render(<>{readPrToolCard.renderExpanded(toolContext)}</>)

    expect(screen.getByText("PR read failed")).toBeInTheDocument()
    expect(screen.getByText("Read PR #72")).toBeInTheDocument()
    expect(screen.getByText("Safe to retry")).toBeInTheDocument()
    expect(screen.getByText("PR#72")).toBeInTheDocument()
  })

  it("renders question and reopen failures with retry guidance", () => {
    const questionContext = context("ask_user_question", {
      input: { questions: [{ question: "Which path?" }, { question: "Retry?" }] },
      parsedResult: { message: "connection unavailable", retryable: true }
    })
    const reopenContext = context("reopen_job", {
      input: { job_ids: [4785, 4786] },
      parsedResult: { message: "job is not closed" }
    })

    render(
      <>
        {askUserQuestionToolCard.renderExpanded(questionContext)}
        {reopenJobToolCard.renderExpanded(reopenContext)}
      </>
    )

    expect(screen.getByText("Ask 2 operator questions")).toBeInTheDocument()
    expect(screen.getByText("Safe to retry")).toBeInTheDocument()
    expect(screen.getByText("Reopen 2 Jobs")).toBeInTheDocument()
    expect(screen.getByText("JOB-4785")).toBeInTheDocument()
    expect(screen.getByText("JOB-4786")).toBeInTheDocument()
  })

  it("keeps repository failures specific to the attempted repository action", () => {
    const attachContext = context("attach_repository", {
      input: { slug: "tkadauke/syrus" },
      parsedResult: { message: "workspace lock wait timeout" }
    })
    const repoInfoContext = context("repo_info", {
      input: { repository: "tkadauke/syrus" },
      parsedResult: { message: "GitHub unavailable" }
    })
    const epicContext = context("propose_epic_with_jobs", {
      input: { title: "Tool cards", jobs: [{ title: "One" }, { title: "Two" }] },
      parsedResult: { message: "validation failed", epic_id: 349 }
    })

    render(
      <>
        {attachRepositoryToolCard.renderExpanded(attachContext)}
        {repoInfoToolCard.renderExpanded(repoInfoContext)}
        {proposeEpicWithJobsToolCard.renderExpanded(epicContext)}
      </>
    )

    expect(screen.getByText("Attach tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("Read repository info for tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("Propose epic: Tool cards with 2 Jobs")).toBeInTheDocument()
    expect(screen.getByText("EPIC-349")).toBeInTheDocument()
  })
})
