import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { PendingActionCard, PendingActionGroupCard, ProposalCard, ProposalEditModal } from "./ProposalCards"
import type { ChatMediaPayload, ChatPayload, ChatPendingAction, ChatPendingActionGroup, ChatProposal } from "../../api/chats"
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

function pendingActionGroup(overrides: Partial<ChatPendingActionGroup> = {}): ChatPendingActionGroup {
  return {
    id: 7,
    label: "Reopen job (2)",
    state: "pending",
    members: [
      { id: 501, label: "Reopen JOB-4162", state: "pending" },
      { id: 502, label: "Reopen JOB-4163", state: "pending" }
    ],
    app_confirm_path: "/api/v1/app/chats/122/pending_action_groups/7/confirm",
    app_reject_path: "/api/v1/app/chats/122/pending_action_groups/7/reject",
    ...overrides
  }
}

function renderGroupCard(group: ChatPendingActionGroup, onNotice = vi.fn()) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(queryKey, { pending_action_groups: [group] })
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <PendingActionGroupCard onNotice={onNotice} pendingActionGroup={group} queryKey={queryKey} />
      </QueryClientProvider>
    </MemoryRouter>
  )
  return { onNotice }
}

describe("PendingActionGroupCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the group label and reveals its member targets on expand", () => {
    renderGroupCard(pendingActionGroup())

    expect(screen.getByText("Reopen job (2)")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "JOB-4162" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show 2 targets" }))

    expect(screen.getByRole("link", { name: "JOB-4162" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-4163" })).toBeInTheDocument()
  })

  it("confirms every member on Confirm all and surfaces the per-item outcome", async () => {
    const confirmed = pendingActionGroup({
      state: "confirmed",
      members: [
        { id: 501, label: "Reopen JOB-4162", state: "confirmed" },
        { id: 502, label: "Reopen JOB-4163", state: "failed", execution_error: "Job isn't closed." }
      ]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      pending_action_groups: [confirmed],
      message: "Confirmed 1 of 2 pending actions; 1 failed."
    }))
    const { onNotice } = renderGroupCard(pendingActionGroup())

    fireEvent.click(screen.getByRole("button", { name: "Confirm all" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Confirmed 1 of 2 pending actions; 1 failed."))
    const [url, init] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/chats/122/pending_action_groups/7/confirm")
    expect(init?.method).toBe("POST")
  })

  it("rejects every member on Reject all", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      pending_action_groups: [pendingActionGroup({ state: "rejected" })],
      message: "Rejected 2 pending actions."
    }))
    const { onNotice } = renderGroupCard(pendingActionGroup())

    fireEvent.click(screen.getByRole("button", { name: "Reject all" }))

    await waitFor(() => expect(onNotice).toHaveBeenCalledWith("Rejected 2 pending actions."))
    const [url] = fetchSpy.mock.calls[0]
    expect(url).toBe("/api/v1/app/chats/122/pending_action_groups/7/reject")
  })

  it("does not show Confirm/Reject controls once the group is resolved", () => {
    renderGroupCard(pendingActionGroup({ state: "rejected" }))

    expect(screen.queryByRole("button", { name: "Confirm all" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reject all" })).not.toBeInTheDocument()
    expect(screen.getByText("Rejected")).toBeInTheDocument()
  })
})

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
    route_to_backlog: false,
    route_label: "Start normally",
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
  chat_images: [{ id: 77, title: "Safari capture", filename: "capture.png", content_type: "image/png", image_url: "/api/v1/app/credentials/documents/77/file" }],
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

function renderProposalEditModal(p: ChatProposal, onNotice = vi.fn()) {
  const queryKey: ChatQueryKey = ["chats", "122", ""]
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  client.setQueryData(queryKey, payloadFor(queryKey, p))
  client.setQueryData(["chat_media", "122"], mediaPayload)
  render(
    <MemoryRouter>
      <QueryClientProvider client={client}>
        <ProposalEditModal chatId="122" onClose={vi.fn()} onNotice={onNotice} proposal={p} queryKey={queryKey} search="" />
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

  it("renders attached image media as a clickable thumbnail preview", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(mediaPayload))

    renderProposalCard(proposal({ media_ids: ["chat_image:77"] }))

    const thumbnail = await screen.findByRole("img", { name: "Safari capture" })
    expect(thumbnail).toHaveAttribute("src", "/api/v1/app/credentials/documents/77/file")
    expect(screen.queryByText("image/png")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Preview Safari capture" }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(screen.getAllByRole("img", { name: "Safari capture" })).toHaveLength(2)
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

describe("ProposalCard routing", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows the selected route on direct Job proposal cards", async () => {
    renderProposalCard(proposal({ kind: "job", kind_label: "Job", route_to_backlog: true, route_label: "Backlog" }))

    expect(screen.getByText("Route")).toBeInTheDocument()
    expect(screen.getAllByText("Backlog").length).toBeGreaterThan(0)
  })

  it("lets operators choose backlog routing before confirming a direct Job proposal", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url.endsWith("/media")) return Promise.resolve(jsonResponse(mediaPayload))
      if (init?.method === "PATCH") return Promise.resolve(jsonResponse(payloadFor(["chats", "122", ""], proposal({ kind: "job", route_to_backlog: true, route_label: "Backlog" }))))

      return Promise.resolve(jsonResponse({}))
    })

    renderProposalEditModal(proposal({ kind: "job", kind_label: "Job" }))
    const routeGroup = await screen.findByRole("group", { name: "Route" })
    fireEvent.click(within(routeGroup).getAllByRole("radio")[1])
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "PATCH")
      expect(patchCall).toBeTruthy()
      expect(JSON.parse(String(patchCall?.[1]?.body))).toMatchObject({
        proposal: { route_to_backlog: true }
      })
    })
  })

  it("lets operators confirm a direct Job proposal to backlog from the card", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "POST") return Promise.resolve(jsonResponse({ message: "Proposal confirmed.", proposal: proposal({ kind: "job", state: "confirmed", proposed: false }) }))

      return Promise.resolve(jsonResponse({}))
    })

    renderProposalCard(proposal({ kind: "job", kind_label: "Job" }))
    fireEvent.click(screen.getByRole("button", { name: "Confirm proposal to backlog" }))

    await waitFor(() => {
      const postCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "POST")
      expect(postCall).toBeTruthy()
      expect(JSON.parse(String(postCall?.[1]?.body))).toEqual({ route_to_backlog: true })
    })
  })

  it("lets operators confirm a direct Job proposal for implementation from the card", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "POST") return Promise.resolve(jsonResponse({ message: "Proposal confirmed.", proposal: proposal({ kind: "job", state: "confirmed", proposed: false }) }))

      return Promise.resolve(jsonResponse({}))
    })

    renderProposalCard(proposal({ kind: "job", kind_label: "Job", route_to_backlog: true, route_label: "Backlog" }))
    fireEvent.click(screen.getByRole("button", { name: "Confirm proposal and implement" }))

    await waitFor(() => {
      const postCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "POST")
      expect(postCall).toBeTruthy()
      expect(JSON.parse(String(postCall?.[1]?.body))).toEqual({ route_to_backlog: false })
    })
  })

  it("does not show route selection for Epic bundle child edits", async () => {
    renderProposalCard(proposal({
      kind: "epic",
      kind_label: "Epic",
      epic_bundle: true,
      children: [{
        id: 18,
        title: "Child",
        slug: "child",
        body: "Build it.",
        state: "proposed",
        state_label: "Proposed",
        proposed: true,
        repository_slug: "tkadauke/syrus",
        dependencies: [],
        depends_on_job_ids: [],
        depends_on_epic_ids: [],
        media_ids: [],
        dependency_details: [],
        app_update_path: "/api/v1/app/chats/122/proposals/18",
        app_reject_path: "/api/v1/app/chats/122/proposals/18/reject"
      }]
    }))

    fireEvent.click(screen.getByRole("button", { name: "Edit child" }))

    expect(await screen.findByRole("dialog", { name: "Edit proposal" })).toBeInTheDocument()
    expect(screen.queryByRole("group", { name: "Route" })).not.toBeInTheDocument()
  })
})
