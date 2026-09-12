import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatToolGroupItem } from "../../api/chats"
import { ToolGroup } from "./MessageCards"
import { buildToolErrorCardModel, ToolErrorCard } from "./toolErrorCard"

type ToolCall = ChatToolGroupItem["calls"][number]

function call(overrides: Partial<ToolCall> = {}): ToolCall {
  return {
    message_id: 1,
    tool_name: "read_job",
    raw_name: "mcp__syrus-chat-sidecar__read_job",
    detail: "JOB-4786",
    display_label: "Read job",
    progress_label: "Reading",
    raw_payload: { job_id: 4786 },
    result_body: JSON.stringify({ message: "tool failed" }),
    result_json: { message: "tool failed" },
    result_error: true,
    result_kind: "error",
    result_summary: "tool failed",
    ...overrides
  }
}

describe("ToolErrorCard", () => {
  it("falls back cleanly for unknown errors without an error_class", () => {
    const model = buildToolErrorCardModel(call({
      tool_name: "diagnose_workspace",
      raw_name: "mcp__plugin-sidecar__diagnose_workspace",
      display_label: "Diagnose workspace",
      raw_payload: { repository: "tkadauke/syrus" },
      result_body: "",
      result_json: { reason: "provider returned an empty error object" }
    }))

    expect(model).toMatchObject({
      toolLabel: "Diagnose workspace",
      mcpServerId: "plugin-sidecar",
      mcpToolId: "diagnose_workspace",
      errorClass: null,
      errorMessage: "provider returned an empty error object",
      retryable: null,
      sideEffectRisk: "medium",
      recovery: "Review raw details and target state before retrying."
    })
  })

  it("uses complete parsed JSON for long error messages instead of truncated result text", () => {
    const longMessage = `Validation failed: ${"tool output was too noisy. ".repeat(24)}Check the generated proposal body.`
    const model = buildToolErrorCardModel(call({
      tool_name: "propose_job",
      raw_name: "syrus-chat-sidecar.propose_job",
      display_label: "Propose job",
      raw_payload: { title: "Add recovery cards", target_epic_id: 349 },
      result_body: JSON.stringify({ message: longMessage }).slice(0, 80),
      result_json: { error_class: "ActiveRecord::RecordInvalid", message: longMessage, retryable: false }
    }))

    expect(model.errorMessage).toBe(longMessage)
    expect(model.errorMessage.length).toBeGreaterThan(300)
    expect(model.errorClass).toBe("ActiveRecord::RecordInvalid")
    expect(model.affectedEntityIds).toContain("epic:349")
    expect(model.recovery).toBe("Correct the input, permissions, or missing resource before trying again.")
  })

  it("flags failed pending actions as side-effecting and preserves IDs", () => {
    const model = buildToolErrorCardModel(call({
      tool_name: "retry_job",
      raw_name: "mcp__syrus-chat-sidecar__retry_job",
      display_label: "Retry job",
      raw_payload: { pending_action_id: 77, job_id: 4786 },
      result_json: {
        message: "confirmation expired while retrying",
        pending_confirmation_id: 77,
        retryable: true
      }
    }))

    expect(model.retryable).toBe(true)
    expect(model.sideEffectRisk).toBe("medium")
    expect(model.affectedEntityIds).toEqual(expect.arrayContaining(["pending_action:77", "job:4786"]))
    expect(model.recovery).toBe("Check whether the action partially completed before retrying.")
  })

  it("warns before retrying failed destructive tools", () => {
    const model = buildToolErrorCardModel(call({
      tool_name: "delete_proposal",
      raw_name: "mcp__syrus-chat-sidecar__delete_proposal",
      display_label: "Delete proposal",
      raw_payload: { proposal_id: 42 },
      result_json: { message: "database connection unavailable", retryable: true }
    }))

    expect(model.retryable).toBe(true)
    expect(model.sideEffectRisk).toBe("high")
    expect(model.recovery).toBe("Inspect target state and raw details before retrying; this tool may have partially changed data.")
  })

  it("renders recovery copy and keeps raw debugging details collapsed by default", () => {
    const { container } = render(<ToolErrorCard call={call({
      result_json: { message: "GitHub unavailable", retryable: true }
    })} />)
    const recovery = screen.getByText("Safe to retry after the transient dependency recovers.")

    expect(screen.getByText("Read job failed")).toBeInTheDocument()
    expect(screen.getByText("Recovery")).toBeInTheDocument()
    expect(recovery.tagName).toBe("P")
    expect(recovery).not.toHaveClass("truncate")
    expect(screen.getByText("Error details")).toBeInTheDocument()
    expect(container.querySelector("details")?.open).toBe(false)
  })

  it("preserves the tool group's collapsed-by-default behavior and exposes raw details after expansion", async () => {
    const item: ChatToolGroupItem = {
      type: "tool_group",
      tool: "Write workspace file",
      calls: [
        call({
          tool_name: "write_workspace_file",
          raw_name: "mcp__syrus-chat-sidecar__write_workspace_file",
          detail: "app/models/job.rb",
          display_label: "Write workspace file",
          progress_label: "Writing",
          raw_payload: { path: "app/models/job.rb" },
          result_json: { message: "lock wait timeout", retryable: true },
          result_summary: "lock wait timeout"
        })
      ],
      collapsed_by_default: true
    }

    render(<ToolGroup item={item} />)

    expect(screen.getByText("Failed")).toBeInTheDocument()
    expect(screen.queryByText("Write workspace file failed")).not.toBeInTheDocument()

    fireEvent.click(screen.getByText("Write workspace file"))

    expect(await screen.findByText("Write workspace file failed")).toBeInTheDocument()
    expect(screen.getByText("Raw details")).toBeInTheDocument()
    expect(screen.getByText("Check whether the action partially completed before retrying.")).toBeInTheDocument()
  })
})
