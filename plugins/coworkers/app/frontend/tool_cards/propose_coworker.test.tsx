import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeCoworkerToolCard from "./propose_coworker"
import proposeCoworkerGrantsToolCard from "./propose_coworker_grants"

describe("propose_coworker tool card", () => {
  it("renders every normalized field that confirmation will execute", () => {
    const context: ToolCardContext = {
      toolName: "propose_coworker",
      resultBody: "{}",
      resultError: false,
      input: { name: "  Raw Maya  ", handle: "@RAW-MAYA", workspace_repo: " https://example.invalid/raw ", grants: ["workspace.files", "workspace.files"] },
      parsedResult: {
        pending_action_id: 501,
        state: "pending",
        coworker: {
          name: "Maya",
          handle: "maya",
          workspace_repo: "https://github.com/acme/homes.git",
          about: "Research lead",
          color_key: "coral-deep",
          avatar_key: "comet",
          chat_provider: "codex",
          chat_model: "gpt-5.6-sol",
          chat_effort: "high",
          grants: ["workspace.files", "syrus.read_jobs"]
        }
      }
    }

    render(<>{proposeCoworkerToolCard.renderExpanded(context)}</>)

    for (const value of [
      "Maya",
      "@maya",
      "https://github.com/acme/homes.git",
      "Research lead",
      "coral-deep",
      "comet",
      "codex",
      "gpt-5.6-sol",
      "high",
      "workspace.files, syrus.read_jobs"
    ])
      expect(screen.getByText(value)).toBeInTheDocument()
    expect(screen.queryByText("Raw Maya")).not.toBeInTheDocument()
    expect(screen.queryByText("@RAW-MAYA")).not.toBeInTheDocument()
  })

  it("renders a grant escalation from its normalized pending payload", () => {
    const context: ToolCardContext = {
      toolName: "propose_coworker_grants",
      resultBody: "{}",
      resultError: false,
      input: { coworker_id: 7, grants: ["workspace.shell", "workspace.shell"] },
      parsedResult: {
        pending_action_id: 502,
        state: "pending",
        grant_escalation: { coworker_id: 7, handle: "maya", grants: ["workspace.shell"] }
      }
    }

    render(<>{proposeCoworkerGrantsToolCard.renderExpanded(context)}</>)

    expect(screen.getByText("@maya")).toBeInTheDocument()
    expect(screen.getByText("workspace.shell")).toBeInTheDocument()
    expect(screen.getByText("pending")).toBeInTheDocument()
  })
})
