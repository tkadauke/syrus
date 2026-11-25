import { act, render, renderHook, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ChatPayload } from "../../api/chats"
import { applyAttention, attentionEvents, attentionSnapshot, hasTabAttention, useWorkspaceTabAttention, workspaceTabBadge } from "./workspaceTabAttention"
import { defaultWorkspaceTab } from "./workspaceTabs"

function payload(overrides: Record<string, unknown> = {}, chat: Record<string, unknown> = {}): ChatPayload {
  return {
    chat: { id: 8, ...chat },
    video_walkthroughs: [],
    preview_panels: [],
    workspace_tabs: [],
    ...overrides
  } as unknown as ChatPayload
}

const whiteboardTab = { id: "whiteboard.canvas", label: "Whiteboard", label_key: null, component: "whiteboard/WhiteboardTab", order: 0 }
const genericTab = { id: "acme.board", label: "Board", label_key: null, component: "acme/Board", order: 1, data: { rev: 1 } }
const t = (key: string, options?: Record<string, unknown>) => (options?.count ? `${key}:${options.count}` : key)

describe("attentionEvents", () => {
  it("reports the media delta as a countable event", () => {
    const events = attentionEvents(attentionSnapshot(payload({}, { chat_image_count: 1 })), attentionSnapshot(payload({}, { chat_image_count: 3 })))
    expect(events).toEqual([{ tab: "media", count: 2 }])
  })

  it("reports a first media artifact so a newly revealed Media tab can be badged", () => {
    const events = attentionEvents(attentionSnapshot(payload()), attentionSnapshot(payload({}, { typed_artifact_count: 1 })))
    expect(events).toEqual([{ tab: "media", count: 1 }])
  })

  it("flags a whiteboard mutation and a generic plugin data change without counts, but not unloaded boards", () => {
    const before = payload({ workspace_tabs: [whiteboardTab, genericTab], whiteboard: { loaded: false, version: 0 } })
    const loaded = payload({ workspace_tabs: [whiteboardTab, genericTab], whiteboard: { loaded: true, version: 1 } })
    expect(attentionEvents(attentionSnapshot(before), attentionSnapshot(loaded))).toEqual([])

    const mutated = payload({
      workspace_tabs: [whiteboardTab, { ...genericTab, data: { rev: 2 } }],
      whiteboard: { loaded: true, version: 2 }
    })
    expect(attentionEvents(attentionSnapshot(loaded), attentionSnapshot(mutated))).toEqual([{ tab: "plugin:whiteboard.canvas" }, { tab: "plugin:acme.board" }])
  })

  it("flags new and updated preview panels", () => {
    const panel = { id: 4, title: "Mock", file_count: 1, current_version_id: 1 }
    const withPanel = payload({ preview_panels: [panel] })
    expect(attentionEvents(attentionSnapshot(payload()), attentionSnapshot(withPanel))).toEqual([{ tab: "preview:4" }])
    expect(attentionEvents(attentionSnapshot(withPanel), attentionSnapshot(payload({ preview_panels: [{ ...panel, current_version_id: 2 }] })))).toEqual([
      { tab: "preview:4" }
    ])
  })

  it("ignores a different chat", () => {
    expect(attentionEvents(attentionSnapshot(payload()), attentionSnapshot(payload({}, { id: 9, chat_image_count: 4 })))).toEqual([])
  })
})

describe("applyAttention", () => {
  it("accumulates counts and keeps dots separate", () => {
    let map = applyAttention({}, { tab: "media", count: 2 })
    map = applyAttention(map, { tab: "media", count: 3 })
    expect(map.media).toEqual({ count: 5, dot: false })
    expect(applyAttention({}, { tab: "plugin:x" })["plugin:x"]).toEqual({ count: 0, dot: true })
    expect(hasTabAttention(map)).toBe(true)
    expect(hasTabAttention({})).toBe(false)
  })
})

describe("workspaceTabBadge", () => {
  it("renders an accessible numeric badge capped at 9+", () => {
    render(<>{workspaceTabBadge({ count: 12, dot: false }, t)}</>)
    expect(screen.getByText("9+")).toHaveAttribute("aria-hidden", "true")
    expect(screen.getByText("tab_attention_new_items:12")).toHaveClass("sr-only")
  })

  it("renders an unnumbered dot with screen-reader text", () => {
    render(<>{workspaceTabBadge({ count: 0, dot: true }, t)}</>)
    expect(screen.getByText("tab_attention_new_activity")).toHaveClass("sr-only")
    expect(screen.getByTestId("workspace-tab-badge")).not.toHaveTextContent(/\d/)
  })

  it("renders nothing without attention", () => {
    expect(workspaceTabBadge(undefined, t)).toBeUndefined()
  })
})

describe("useWorkspaceTabAttention", () => {
  it("badges hidden tabs, ignores the visible tab, and clears on view", () => {
    const { result, rerender } = renderHook(({ data, visible }) => useWorkspaceTabAttention(data, visible), {
      initialProps: { data: payload(), visible: null as "media" | null }
    })

    rerender({ data: payload({}, { chat_image_count: 1 }), visible: null })
    expect(result.current.attention.media).toEqual({ count: 1, dot: false })

    rerender({ data: payload({}, { chat_image_count: 3 }), visible: null })
    expect(result.current.attention.media).toEqual({ count: 3, dot: false })

    rerender({ data: payload({}, { chat_image_count: 3 }), visible: "media" })
    expect(result.current.attention.media).toBeUndefined()

    rerender({ data: payload({}, { chat_image_count: 5 }), visible: "media" })
    expect(result.current.attention.media).toBeUndefined()

    act(() => result.current.notify({ tab: "jobs", count: 2 }))
    expect(result.current.attention.jobs).toEqual({ count: 2, dot: false })
    act(() => result.current.notify({ tab: "media", count: 1 }))
    expect(result.current.attention.media).toBeUndefined()
  })
})

describe("defaultWorkspaceTab", () => {
  it("does not prefer the whiteboard because it has content", () => {
    const data = payload(
      {
        workspace_tabs: [whiteboardTab],
        whiteboard: { loaded: true, version: 3, elements: [{ id: "a" }] }
      },
      { chat_image_count: 1 }
    )
    expect(defaultWorkspaceTab(data)).toBe("media")
  })
})
