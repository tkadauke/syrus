import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { ChatPendingActionInline } from "@app/api/chats"
import type { ToolCardContext } from "@app/pluginToolCards"
import proposeCoworkerToolCard from "./propose_coworker"

function live(state: ChatPendingActionInline["state"], overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id: 501,
    action: "create_coworker",
    state,
    label: "Create coworker @maya",
    detail: null,
    app_confirm_path: "/confirm",
    app_reject_path: "/reject",
    ...overrides
  }
}
function context(livePendingAction: ChatPendingActionInline): ToolCardContext {
  return {
    toolName: "propose_coworker",
    resultBody: "{}",
    resultError: false,
    input: {},
    livePendingAction,
    parsedResult: {
      pending_action_id: 501,
      state: "pending",
      coworker: {
        name: "Maya",
        handle: "maya",
        workspace_repo: "https://github.com/acme/homes.git",
        branch: "coworkers/maya",
        about: "Research lead",
        color_key: "coral-deep",
        avatar_key: "comet",
        chat_provider: "codex",
        chat_model: "gpt-5.6-sol",
        chat_effort: "high",
        grants: ["workspace.files", "syrus.propose_job"],
        grant_policies: { "workspace.files": "auto", "syrus.propose_job": "confirm" }
      }
    }
  }
}
function renderCard(action: ChatPendingActionInline) {
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return render(<QueryClientProvider client={client}>{proposeCoworkerToolCard.renderExpanded(context(action))}</QueryClientProvider>)
}

describe("propose_coworker tool card", () => {
  it("renders the proposed configuration and edits About with the keyboard", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ messages: [] }), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const view = renderCard(live("pending", { app_update_path: "/update" }))
    for (const value of [
      "Maya",
      "@maya",
      "https://github.com/acme/homes.git",
      "coworkers/maya",
      "codex · gpt-5.6-sol",
      "workspace.files",
      "auto",
      "syrus.propose_job",
      "confirm"
    ])
      expect(screen.getByText(value)).toBeInTheDocument()
    const about = screen.getByRole("textbox", { name: "About (optional)" })
    fireEvent.change(about, { target: { value: "role: Research director" } })
    const save = screen.getByRole("button", { name: "Save About text" })
    save.focus()
    expect(save).toHaveFocus()
    fireEvent.click(save)
    await waitFor(() =>
      expect(window.fetch).toHaveBeenCalledWith(
        "/update",
        expect.objectContaining({ method: "PATCH", body: JSON.stringify({ about: "role: Research director" }) })
      )
    )
    view.unmount()
    renderCard(live("confirmed", { review: { about: "role: Research director" }, outcome: { coworker_id: 12, chat_id: 44 } }))
    expect(screen.getByRole("textbox", { name: "About (optional)" })).toHaveValue("role: Research director")
    expect(screen.getByRole("textbox", { name: "About (optional)" })).toBeDisabled()
  })

  it("shows confirmed links to the coworker and main chat", () => {
    renderCard(live("confirmed", { outcome: { coworker_id: 12, chat_id: 44 } }))
    expect(screen.getByRole("link", { name: "Open coworker" })).toHaveAttribute("href", "/coworkers/12")
    expect(screen.getByRole("link", { name: "Open main chat" })).toHaveAttribute("href", "/chats/44")
    expect(screen.getByRole("textbox")).toBeDisabled()
  })

  it("shows the rejected state", () => {
    renderCard(live("rejected", { reason: "Owner declined the proposal." }))
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Owner declined the proposal.")).toBeInTheDocument()
  })

  it("shows the Coworkers::Create failure reason", () => {
    renderCard(live("failed", { execution_error: "Push access was denied." }))
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Push access was denied.")).toBeInTheDocument()
  })
})
