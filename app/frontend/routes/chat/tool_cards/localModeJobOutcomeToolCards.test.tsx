import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import openInLocalModeCard, { examples as openInLocalModeExamples } from "./open_in_local_mode"
import cancelLocalModeCard from "./cancel_local_mode"
import createCodingJobCard from "./create_coding_job"
import openInCodingModeCard, { examples as openInCodingModeExamples } from "./open_in_coding_mode"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

// Parity guard for the Local Mode job-outcome tool card family (the tool-card work /
// Each card is a thin re-export of ../localModeJobOutcomeCard,
// so the shared parsing/rendering is covered once in
// localModeJobOutcomeCard.test.tsx; this just guards the tool-name binding.
const CARDS: Array<[string, ToolCardRenderer]> = [
  ["open_in_local_mode", openInLocalModeCard],
  ["cancel_local_mode", cancelLocalModeCard],
  ["create_coding_job", createCodingJobCard],
  ["open_in_coding_mode", openInCodingModeCard]
]
const LEGACY_NULL_FALLBACK_CARDS = CARDS.filter(([name]) => !["cancel_local_mode", "create_coding_job"].includes(name))

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("Local Mode job-outcome tool card family", () => {
  it("registers each card under a unique, exact tool name", () => {
    const names = CARDS.map(([name]) => name)
    expect(new Set(names).size).toBe(names.length)
    for (const [name, card] of CARDS) expect(card.toolName).toBe(name)
  })

  it.each(LEGACY_NULL_FALLBACK_CARDS)("%s falls back to null for a malformed payload", (_name, card) => {
    expect(card.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(card.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })

  it("cancel_local_mode owns its empty and error states", () => {
    expect(cancelLocalModeCard.collapsedSummary?.(context({ input: { job_id: 42 }, parsedResult: {} }))).toBe("No job outcome returned")
    expect(cancelLocalModeCard.renderExpanded(context({ input: { job_id: 42 }, parsedResult: {} }))).not.toBeNull()
    expect(cancelLocalModeCard.collapsedSummary?.(context({ resultBody: "not allowed", resultError: true }))).toBe("Local Mode cancellation failed")
    expect(cancelLocalModeCard.renderExpanded(context({ resultBody: "not allowed", resultError: true }))).not.toBeNull()
  })

  it("uses shared provider normalizers for MCP names and result envelopes", () => {
    const payload = { job_id: 42, job_state: "closed", message: "closed" }
    expect(normalizedToolName("mcp__syrus-chat-sidecar__cancel_local_mode")).toBe("cancel_local_mode")
    expect(normalizedToolCardParsedResult({ content: [{ type: "text", text: JSON.stringify(payload) }] })).toEqual(payload)
    expect(normalizedToolCardParsedResult({ structured_content: payload })).toEqual(payload)
  })

  it.each([
    {
      content: [{ type: "text", text: JSON.stringify({ job_id: 42, job_state: "queued", repository_slug: "tkadauke/syrus", message: "Created **JOB-42**." }) }]
    },
    { structured_content: { job_id: 42, job_state: "queued", repository_slug: "tkadauke/syrus", message: "Created **JOB-42**." } }
  ])("renders create_coding_job input and result through a normalized provider envelope", (envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(
      <>{createCodingJobCard.renderExpanded(context({ input: { title: "Create a card", body: "Render **Markdown**.", repository_id: 7 }, parsedResult }))}</>
    )

    expect(screen.getByRole("heading", { name: "Create a card" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/7")
    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("href", "/jobs/42")
  })

  it("renders create_coding_job errors with the original request", () => {
    const errorContext = context({
      input: { title: "Create a card", body: "Render the request.", repository_id: 7 },
      resultBody: "Repository is unavailable.",
      resultError: true
    })

    expect(createCodingJobCard.collapsedSummary?.(errorContext)).toBe("Coding job creation failed")
    render(<>{createCodingJobCard.renderExpanded(errorContext)}</>)
    expect(screen.getByRole("heading", { name: "Create a card" })).toBeInTheDocument()
    expect(screen.getByText("Repository is unavailable.")).toBeInTheDocument()
  })

  it.each([
    {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            job_id: 42,
            job_state: "coding",
            branch_name: "syrus/direct-42",
            repository_slug: "tkadauke/syrus",
            message: "Opened on `syrus/direct-42`."
          })
        }
      ]
    },
    {
      structured_content: {
        job_id: 42,
        job_state: "coding",
        branch_name: "syrus/direct-42",
        repository_slug: "tkadauke/syrus",
        message: "Opened on `syrus/direct-42`."
      }
    }
  ])("renders open_in_local_mode through a normalized provider envelope", (envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{openInLocalModeCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByText("syrus/direct-42", { selector: "code" })).toBeInTheDocument()
  })

  it("renders an open_in_local_mode error result", () => {
    const errorContext = context({ input: { job_id: 42 }, resultBody: "Local Mode daemon is unavailable.", resultError: true })

    expect(openInLocalModeCard.collapsedSummary?.(errorContext)).toBe("Failed to open Local Mode")
    render(<>{openInLocalModeCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Local Mode daemon is unavailable.")).toBeInTheDocument()
  })

  it.each([
    {
      content: [
        {
          type: "text",
          text: JSON.stringify({
            job_id: 42,
            job_state: "coding",
            branch_name: "syrus/direct-42",
            checkout_branch: "coding/chat-98",
            repository_slug: "tkadauke/syrus",
            message: "Opened in **Coding Mode**."
          })
        }
      ]
    },
    {
      structured_content: {
        job_id: 42,
        job_state: "coding",
        branch_name: "syrus/direct-42",
        checkout_branch: "coding/chat-98",
        repository_slug: "tkadauke/syrus",
        message: "Opened in **Coding Mode**."
      }
    }
  ])("renders open_in_coding_mode through a normalized provider envelope", (envelope) => {
    const parsedResult = normalizedToolCardParsedResult(envelope)
    expect(normalizedToolName("mcp__syrus-chat-sidecar__open_in_coding_mode")).toBe("open_in_coding_mode")
    render(<>{openInCodingModeCard.renderExpanded(context({ toolName: "mcp__syrus-chat-sidecar__open_in_coding_mode", parsedResult }))}</>)

    expect(screen.getByRole("link", { name: /JOB-42/ })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("button", { name: "Copy syrus/direct-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy coding/chat-98 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText("Coding Mode", { selector: "strong" })).toBeInTheDocument()
  })

  it("renders an open_in_coding_mode error result", () => {
    const errorContext = context({ input: { job_id: 42 }, resultBody: "The job is not ready for Coding Mode.", resultError: true })

    expect(openInCodingModeCard.collapsedSummary?.(errorContext)).toBe("Failed to open Coding Mode")
    render(<>{openInCodingModeCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("The job is not ready for Coding Mode.")).toBeInTheDocument()
  })

  it("registers reviewable open_in_coding_mode success and error examples", () => {
    expect(openInCodingModeExamples).toEqual([
      expect.objectContaining({ id: "opened", parsedResult: expect.objectContaining({ checkout_branch: "coding/chat-98" }) }),
      expect.objectContaining({ id: "error", resultError: true })
    ])
  })

  it("registers reviewable open_in_local_mode success and error examples", () => {
    expect(openInLocalModeExamples).toEqual([
      expect.objectContaining({ id: "opened", parsedResult: expect.objectContaining({ branch_name: expect.stringContaining("syrus/direct-") }) }),
      expect.objectContaining({ id: "error", resultError: true })
    ])

    const successContext = toolCardContextForExample("open_in_local_mode", openInLocalModeExamples[0])
    render(<>{openInLocalModeCard.renderExpanded(successContext)}</>)
    expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("button", { name: /Copy syrus\/direct-4225.* to clipboard/ })).toBeInTheDocument()
    expect(screen.getByText(/syrus\/direct-4225/, { selector: "code" })).toBeInTheDocument()

    const errorContext = toolCardContextForExample("open_in_local_mode", openInLocalModeExamples[1])
    expect(openInLocalModeCard.collapsedSummary?.(errorContext)).toBe("Failed to open Local Mode")
    render(<>{openInLocalModeCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("Local Mode daemon is unavailable.")).toBeInTheDocument()
  })

  it.each(CARDS)("%s summarizes and wires through a well-formed payload", (_name, card) => {
    const parsedResult = { job_id: 42, job_state: "coding", message: "done" }
    expect(card.collapsedSummary?.(context({ parsedResult }))).toBe("done")
    expect(card.renderExpanded(context({ parsedResult }))).not.toBeNull()
  })
})
