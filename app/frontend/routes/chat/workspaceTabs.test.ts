import { describe, expect, it } from "vitest"
import type { ChatMessageItem, ChatPayload } from "../../api/chats"
import { availableWorkspaceTabs, mediaTabVisible, workspaceTabClass } from "./workspaceTabs"

function makePayload(overrides: Partial<ChatPayload> = {}): ChatPayload {
  return {
    chat: {
      id: 1,
      title: "Test chat",
      title_pending: false,
      pinned: false,
      pinned_context: null,
      chat_path: "/chats/1",
      repository: { id: 2, slug: "acme/repo", repository_path: "/repositories/2" },
      mode: "planning",
      stop_requested_at: null,
      cumulative_input_tokens: 0,
      cumulative_output_tokens: 0,
      cumulative_cost_usd: 0,
      confirmed_proposal_count: 0,
      linked_direct_job_count: 0,
      whiteboard_snapshot_count: 0,
      typed_artifact_count: 0
    },
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
    whiteboard: { version: 1, elements: [], appState: {}, files: {} },
    paths: {
      credentials_path: "/credentials",
      repositories_path: "/repositories",
      app_messages_path: "/api/v1/app/chats/1/messages",
      app_message_path: "/api/v1/app/chats/1/message",
      app_rename_path: "/api/v1/app/chats/1/rename",
      app_clear_path: "/api/v1/app/chats/1/messages",
      app_branch_path: "/api/v1/app/chats/1/branch",
      app_share_path: "/api/v1/app/chats/1/share",
      app_enqueue_message_path: "/api/v1/app/chats/1/queued_messages",
      app_scheduled_messages_path: "/api/v1/app/chats/1/scheduled_messages",
      app_stop_path: "/api/v1/app/chats/1/stop",
      app_daemon_connection_path: "/api/v1/app/chats/1/daemon_connection",
      app_switch_provider_path: "/api/v1/app/chats/1/switch_provider",
      app_bookmarks_path: "/api/v1/app/chats/1/bookmarks",
      app_attachments_path: "/api/v1/app/chats/1/attachments",
      app_video_walkthroughs_path: "/api/v1/app/chats/1/video_walkthroughs",
      app_whiteboard_path: "/api/v1/app/chats/1/whiteboard",
      app_scratchpad_reorder_path: "/api/v1/app/chats/1/scratchpad_items/reorder"
    },
    gemini_configured: false,
    walkthroughs_enabled: false,
    coding_mode_enabled: false,
    local_mode_enabled: false,
    local_tunnel_connected: false,
    preview_panels: [],
    workspace_tabs: [],
    ...overrides
  } as ChatPayload
}

function imageMessage(): ChatMessageItem {
  return {
    type: "message",
    id: 1,
    role: "user",
    text: "",
    bookmarkable: false,
    attachments: [{ name: "screenshot.png", mime_type: "image/png", data: "data:image/png;base64,AAAA" }]
  }
}

describe("mediaTabVisible", () => {
  it("is false when the chat has no images, walkthroughs, snapshots, or artifacts", () => {
    expect(mediaTabVisible(makePayload())).toBe(false)
  })

  it("is true when a message has an image attachment", () => {
    expect(mediaTabVisible(makePayload({ messages: [imageMessage()] }))).toBe(true)
  })

  it("is true when the chat has a video walkthrough", () => {
    expect(mediaTabVisible(makePayload({
      video_walkthroughs: [{
        id: 1,
        title: "Walkthrough",
        state: "analyzed",
        duration_seconds: 30,
        byte_size: 1024,
        error_message: null,
        has_video: true,
        created_at: "2026-08-01T00:00:00Z"
      }]
    }))).toBe(true)
  })

  it("is true when the chat has whiteboard snapshots", () => {
    const payload = makePayload()
    payload.chat.whiteboard_snapshot_count = 1
    expect(mediaTabVisible(payload)).toBe(true)
  })

  it("is true when the chat has typed artifacts", () => {
    const payload = makePayload()
    payload.chat.typed_artifact_count = 1
    expect(mediaTabVisible(payload)).toBe(true)
  })
})

describe("workspaceTabClass", () => {
  it("caps every tab at a third of the viewport width and truncates instead of wrapping or growing", () => {
    expect(workspaceTabClass(false)).toContain("max-w-[33vw]")
    expect(workspaceTabClass(false)).toContain("truncate")
    expect(workspaceTabClass(false)).toContain("shrink-0")
    expect(workspaceTabClass(true)).toContain("max-w-[33vw]")
    expect(workspaceTabClass(true)).toContain("truncate")
    expect(workspaceTabClass(true)).toContain("shrink-0")
  })
})

describe("availableWorkspaceTabs", () => {
  it("excludes the media tab when there is nothing to show", () => {
    expect(availableWorkspaceTabs(makePayload())).not.toContain("media")
  })

  it("includes the media tab once there is an image attachment", () => {
    expect(availableWorkspaceTabs(makePayload({ messages: [imageMessage()] }))).toContain("media")
  })

  it("excludes the jobs tab when there are no confirmed proposals or linked direct jobs", () => {
    expect(availableWorkspaceTabs(makePayload())).not.toContain("jobs")
  })

  it("includes the jobs tab once there is a confirmed proposal", () => {
    const payload = makePayload()
    payload.chat.confirmed_proposal_count = 1
    expect(availableWorkspaceTabs(payload)).toContain("jobs")
  })

  it("includes the jobs tab once there is a linked direct job", () => {
    const payload = makePayload()
    payload.chat.linked_direct_job_count = 1
    expect(availableWorkspaceTabs(payload)).toContain("jobs")
  })

  it("excludes the diff tab when the tunnel is connected but the chat has switched back to planning mode", () => {
    const payload = makePayload({ local_mode_enabled: true, local_tunnel_connected: true })
    payload.chat.mode = "planning"
    expect(availableWorkspaceTabs(payload)).not.toContain("diff")
  })

  it("includes the diff tab when in local mode with a connected tunnel", () => {
    const payload = makePayload({ local_mode_enabled: true, local_tunnel_connected: true })
    payload.chat.mode = "local"
    expect(availableWorkspaceTabs(payload)).toContain("diff")
  })

  it("excludes the diff tab when local mode is disabled instance-wide", () => {
    const payload = makePayload({ local_mode_enabled: false, local_tunnel_connected: true })
    payload.chat.mode = "local"
    expect(availableWorkspaceTabs(payload)).not.toContain("diff")
  })
})
