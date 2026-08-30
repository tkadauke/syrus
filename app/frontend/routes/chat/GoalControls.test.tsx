import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../../testSupport"
import type { ChatGoal, ChatPayload } from "../../api/chats"
import { GoalControls } from "./GoalControls"

function goal(overrides: Partial<ChatGoal> = {}): ChatGoal {
  return {
    id: 77,
    chat_session_id: 122,
    user_id: 9,
    repository_id: 2,
    prompt: "Ship the goal UI",
    completion_condition: "All controls are tested",
    mode_snapshot: { mode: "planning" },
    status: "active",
    approval_policy: "manual",
    auto_file_proposals: false,
    auto_submit_jobs: false,
    iteration_count: 2,
    terminal_at: null,
    terminal_reason: null,
    terminal_details: null,
    created_at: "2026-08-29T10:00:00Z",
    updated_at: "2026-08-29T10:30:00Z",
    ...overrides
  }
}

function payload(overrides: Partial<ChatPayload> = {}): ChatPayload {
  const activeGoal = goal()
  return {
    chat: {
      id: 122,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/122",
      repository: { id: 2, slug: "tkadauke/syrus" },
      mode: "planning",
      active_goal: activeGoal,
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
    },
    active_goal: activeGoal,
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    switching_provider: false,
    has_more_older: false,
    messages: [],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    video_walkthroughs: [],
    preview_panels: [],
    workspace_tabs: [],
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/122/messages",
      app_message_path: "/api/v1/app/chats/122/message",
      app_rename_path: "/api/v1/app/chats/122/rename",
      app_clear_path: "/api/v1/app/chats/122/messages",
      app_branch_path: "/api/v1/app/chats/122/branch",
      app_share_path: "/api/v1/app/chats/122/share",
      app_enqueue_message_path: "/api/v1/app/chats/122/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/122/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/122/stop",
      app_daemon_connection_path: "/api/v1/app/chats/122/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/122/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/122/bookmarks",
      app_attachments_path: "/api/v1/app/chats/122/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/122/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/122/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/122/scratchpad_items/reorder"
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: true,
    local_mode_enabled: true,
    local_tunnel_connected: false,
    ...overrides
  } as ChatPayload
}

function renderGoalControls(nextPayload = payload(), onNotice = vi.fn()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const queryKey = ["chats", "122", ""] as const
  client.setQueryData(queryKey, nextPayload)
  render(
    <QueryClientProvider client={client}>
      <GoalControls payload={nextPayload} queryKey={queryKey} onNotice={onNotice} />
    </QueryClientProvider>
  )
  return { client, onNotice, queryKey }
}

describe("GoalControls", () => {
  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
  })

  it("renders the active goal strip with status, policy, and completion condition", () => {
    renderGoalControls()

    expect(screen.getByTestId("active-goal-strip")).toHaveTextContent("Active")
    expect(screen.getByText("Ship the goal UI")).toBeInTheDocument()
    expect(screen.getByText(/Done when:/)).toHaveTextContent("All controls are tested")
    expect(screen.getByText("Draft only")).toBeInTheDocument()
  })

  it("renders terminal goal statuses from refreshed payloads", () => {
    renderGoalControls(payload({ active_goal: goal({ status: "blocked", terminal_reason: "needs_operator" }) }))

    expect(screen.getByTestId("active-goal-strip")).toHaveTextContent("Blocked")
    expect(screen.getByText("needs_operator")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Edit goal" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Stop goal" })).toBeDisabled()
  })

  it("pauses, resumes, and stops a goal from visible controls", async () => {
    const fetchSpy = vi.spyOn(window, "fetch")
      .mockResolvedValueOnce(jsonResponse({ ...payload(), message: "Goal paused." }))
      .mockResolvedValueOnce(jsonResponse({ ...payload({ active_goal: goal({ status: "active" }) }), message: "Goal resumed." }))
      .mockResolvedValueOnce(jsonResponse({ ...payload({ active_goal: null }), message: "Goal stopped." }))
    const { onNotice } = renderGoalControls()

    fireEvent.click(screen.getByRole("button", { name: "Pause goal" }))
    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Goal paused."))
    expect(fetchSpy.mock.calls[0][0]).toBe("/api/v1/app/chats/122/goal/pause")

    cleanup()
    renderGoalControls(payload({ active_goal: goal({ status: "paused" }) }), onNotice)
    fireEvent.click(screen.getByRole("button", { name: "Resume goal" }))
    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Goal resumed."))
    expect(fetchSpy.mock.calls[1][0]).toBe("/api/v1/app/chats/122/goal/resume")

    fireEvent.click(screen.getByRole("button", { name: "Stop goal" }))
    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Goal stopped."))
    expect(fetchSpy.mock.calls[2][0]).toBe("/api/v1/app/chats/122/goal/stop")
  })

  it("updates prompt, completion condition, and planning automation policy from the modal", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload()))
    const { onNotice } = renderGoalControls()

    fireEvent.click(screen.getByRole("button", { name: "Edit goal" }))
    fireEvent.change(screen.getByLabelText("Goal prompt"), { target: { value: "Finish the planning rollout" } })
    fireEvent.change(screen.getByLabelText("Completion condition"), { target: { value: "Proposals are filed" } })
    fireEvent.click(screen.getByLabelText("Auto-file proposed Jobs and Epics when the goal policy and permissions allow it."))
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Goal updated."))
    const [, init] = fetchSpy.mock.calls[0]
    expect(JSON.parse(String(init?.body))).toEqual({
      goal: {
        prompt: "Finish the planning rollout",
        completion_condition: "Proposals are filed",
        approval_policy: "manual",
        auto_file_proposals: true,
        auto_submit_jobs: false
      }
    })
  })

  it("labels coding mode automation around job submission and handoff behavior", () => {
    const codingGoal = goal({ mode_snapshot: { mode: "coding" }, auto_submit_jobs: true })
    renderGoalControls(payload({
      active_goal: codingGoal,
      chat: { ...payload().chat, mode: "coding", active_goal: codingGoal }
    }))

    expect(screen.getByText("Coding mode")).toBeInTheDocument()
    expect(screen.getByText("Auto-submit allowed")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Edit goal" }))
    expect(screen.getByText("Coding and local automation")).toBeInTheDocument()
    expect(screen.getByLabelText("Draft generated Jobs and handoffs only. The operator submits them explicitly.")).toBeInTheDocument()
    expect(screen.getByLabelText("Auto-submit generated Jobs and handoffs when the goal policy and permissions allow it.")).toBeInTheDocument()
  })

  it("disables goal controls while the agent is active", () => {
    renderGoalControls(payload({ agent_busy: true }))

    expect(screen.getByRole("button", { name: "Edit goal" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Pause goal" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Stop goal" })).toBeDisabled()
  })
})
