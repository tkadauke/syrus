import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PendingActionCard, ProposalCard } from "./ProposalCards"
import type { ChatMediaPayload, ChatPayload, ChatPendingAction, ChatProposal } from "../../api/chats"
import type { ChatQueryKey } from "./constants"

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

function proposal(overrides: Partial<ChatProposal> = {}): ChatProposal {
  return {
    id: 17,
    kind: "syrus_issue",
    kind_label: "Syrus issue",
    state: "proposed",
    state_label: "Proposed",
    title: "Show media",
    slug: "show-media",
    body: "Use the attached mockup.",
    proposed: true,
    resolved: false,
    epic_bundle: false,
    scoped_repository_slug: "tkadauke/syrus",
    dependency_slugs: [],
    dependencies: [],
    has_dependencies: false,
    target_epic_id: null,
    target_epic_label: null,
    app_update_path: "/api/v1/app/chats/122/proposals/17",
    app_confirm_path: "/api/v1/app/chats/122/proposals/17/confirm",
    app_reject_path: "/api/v1/app/chats/122/proposals/17/reject",
    depends_on_job_ids: [],
    depends_on_epic_ids: [],
    media_ids: [],
    materialized_label: null,
    materialized_path: null,
    materialized: null,
    materialized_epic_state: null,
    materialized_epic_state_path: null,
    ...overrides
  }
}

function payloadFor(queryKey: ChatQueryKey, p: ChatProposal): ChatPayload {
  return {
    chat: {
      id: Number(queryKey[1]),
      title: "Planning",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/122",
      repository: null,
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0
    },
    chat_available: true,
    turn_in_flight: false,
    agent_busy: false,
    switching_provider: false,
    has_more_older: false,
    messages: [{ type: "message", id: 9, role: "assistant", text: "Proposal", content: {}, bookmarkable: true, created_at: "2026-08-30T00:00:00Z", proposal: p }],
    bookmarks: [],
    recent_chats: [],
    pending_actions: [],
    agent_questions: [],
    queued_messages: [],
    scratchpad_items: [],
    video_walkthroughs: [],
    preview_panels: [],
    workspace_tabs: [],
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false,
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/122/messages",
      app_message_path: "/api/v1/app/chats/122/messages/:id",
      app_rename_path: "/api/v1/app/chats/122",
      app_clear_path: "/api/v1/app/chats/122/clear",
      app_branch_path: "/api/v1/app/chats/122/branch",
      app_share_path: "/api/v1/app/chats/122/share",
      app_enqueue_message_path: "/api/v1/app/chats/122/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/122/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/122/stop",
      app_daemon_connection_path: "/api/v1/app/chats/122/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/122/provider",
      app_bookmarks_path: "/api/v1/app/chats/122/bookmarks",
      app_attachments_path: "/api/v1/app/chats/122/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/122/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/122/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/122/scratchpad/reorder"
    }
  }
}

const mediaPayload: ChatMediaPayload = {
  snapshots: [{ id: 42, name: "Annotated layout", snapshot_kind: "manual", element_count: 3, created_at: "2026-08-30T00:00:00Z" }],
  chat_images: [{ id: 77, title: "Safari capture", filename: "capture.png", content_type: "image/png" }],
  typed_artifacts: [],
  whiteboard_has_unsaved_content: false
}

function renderProposalCard(p: ChatProposal, onNotice = vi.fn()) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(queryKey, payloadFor(queryKey, p))
  client.setQueryData(["bootstrap"], { current_user: { id: 1, role: "developer", admin: true } })
  client.setQueryData(["chat_media", "122"], mediaPayload)
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <ProposalCard onNotice={onNotice} prefix="" proposal={p} queryKey={queryKey} />
      </QueryClientProvider>
    </MemoryRouter>
  )
  return { client, onNotice, queryKey }
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

describe("ProposalCard media", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows attached media as compact tiles above the action buttons", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(mediaPayload))

    renderProposalCard(proposal({ media_ids: ["snapshot:42"] }))

    await screen.findByText("Annotated layout")
    const tiles = screen.getByTestId("proposal-media-tiles")
    const actions = screen.getByTestId("proposal-action-footer")
    expect(within(tiles).getByText("Annotated layout")).toBeInTheDocument()
    expect(tiles.compareDocumentPosition(actions) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it("lets proposal edits add and remove media refs", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.endsWith("/media")) {
        return Promise.resolve(jsonResponse(mediaPayload))
      }
      if (init?.method === "PATCH") return Promise.resolve(jsonResponse(payloadFor(["chats", "122", ""], proposal({ media_ids: ["chat_image:77"] }))))

      return Promise.resolve(jsonResponse({}))
    })

    renderProposalCard(proposal({ media_ids: ["snapshot:42"] }))

    fireEvent.click(screen.getByRole("button", { name: "Edit show-media" }))
    await screen.findByRole("button", { name: "Remove Annotated layout" })
    fireEvent.click(screen.getByRole("button", { name: "Remove Annotated layout" }))
    fireEvent.click(await screen.findByRole("button", { name: "Attach Safari capture" }))
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "PATCH")
      expect(patchCall).toBeTruthy()
      expect(JSON.parse(String(patchCall?.[1]?.body))).toMatchObject({
        proposal: { media_ids: ["chat_image:77"] }
      })
    })
  })
})
