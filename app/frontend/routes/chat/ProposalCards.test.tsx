import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PendingActionCard, ProposalCard } from "./ProposalCards"
import type { ChatPendingAction, ChatProposal } from "../../api/chats"
import type { ChatQueryKey } from "./constants"

vi.mock("../../api/bootstrap", () => ({
  fetchBootstrap: vi.fn(() => Promise.resolve({ current_user: { role: "operator", admin: false } }))
}))

function pendingAction(overrides: Partial<ChatPendingAction> = {}): ChatPendingAction {
  return {
    id: 501,
    label: "Rebase JOB-2325",
    detail: null,
    state: "failed",
    action: "rebase_job",
    action_type: null,
    execution_error: "GitHub API timed out.",
    app_confirm_path: "/api/v1/app/chats/122/pending_actions/501/confirm",
    app_reject_path: "/api/v1/app/chats/122/pending_actions/501/reject",
    app_cancel_path: "/api/v1/app/chats/122/pending_actions/501",
    ...overrides
  }
}

function proposal(overrides: Partial<ChatProposal> = {}): ChatProposal {
  return {
    id: 81,
    kind: "job",
    kind_label: "Job",
    state: "confirmed",
    state_label: "Confirmed",
    title: "Add goal UI",
    slug: "add-goal-ui",
    body: "Show active goals in chat.",
    proposed: false,
    resolved: true,
    epic_bundle: false,
    scoped_repository_slug: "tkadauke/syrus",
    dependency_slugs: [],
    dependencies: [],
    has_dependencies: false,
    target_epic_id: null,
    target_epic_label: null,
    app_update_path: "/api/v1/app/chats/122/proposals/81",
    app_confirm_path: "/api/v1/app/chats/122/proposals/81/confirm",
    app_reject_path: "/api/v1/app/chats/122/proposals/81/reject",
    materialized_label: "JOB-3878",
    materialized_path: "/jobs/3878",
    materialized: { kind: "job", job_id: 3878, job_title: "Add goal UI", job_state: "open" },
    goal_provenance: {
      chat_goal_id: 77,
      prompt_snapshot: {
        prompt: "Finish the goal-mode UI",
        completion_condition: "All controls are visible",
        mode_snapshot: { mode: "planning" },
        approval_policy: "manual",
        auto_file_proposals: false,
        auto_submit_jobs: false
      }
    },
    ...overrides
  }
}

function renderCard(action: ChatPendingAction, onNotice = vi.fn()) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(queryKey, { pending_actions: [action] })
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <PendingActionCard onNotice={onNotice} pendingAction={action} queryKey={queryKey} />
      </QueryClientProvider>
    </MemoryRouter>
  )
  return { onNotice }
}

function renderProposalCard(nextProposal: ChatProposal) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <ProposalCard onNotice={() => {}} prefix="" proposal={nextProposal} queryKey={queryKey} />
      </QueryClientProvider>
    </MemoryRouter>
  )
}

describe("PendingActionCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows a dismiss button for a failed pending action and cancels it on click", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({ pending_actions: [], message: "Pending action dismissed." }))
    const { onNotice } = renderCard(pendingAction())

    fireEvent.click(screen.getByRole("button", { name: "Dismiss failed action" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Pending action dismissed."))
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/chats/122/pending_actions/501")
    expect(init?.method).toBe("DELETE")
  })

  it("does not show a dismiss button for a pending (not yet failed) action", () => {
    renderCard(pendingAction({ state: "pending" }))

    expect(screen.queryByRole("button", { name: "Dismiss failed action" })).not.toBeInTheDocument()
  })
})

describe("ProposalCard goal provenance", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows the originating goal and linked materialized Job chip", () => {
    renderProposalCard(proposal())

    expect(screen.getByText("Goal provenance")).toBeInTheDocument()
    expect(screen.getByText("Goal #77").closest("dd")).toHaveAttribute("title", "Finish the goal-mode UI")
    const links = screen.getAllByRole("link", { name: "JOB-3878" })
    expect(links.some((link) => link.getAttribute("href") === "/jobs/3878")).toBe(true)
  })
})
