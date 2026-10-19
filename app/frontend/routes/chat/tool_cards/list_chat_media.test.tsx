import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "../toolRendering"
import listChatMediaToolCard from "./list_chat_media"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "list_chat_media",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("list_chat_media tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(listChatMediaToolCard.toolName).toBe("list_chat_media")
  })

  it("summarizes the collapsed row with a media item count", () => {
    const parsedResult = {
      snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow" }],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png" }]
    }

    expect(listChatMediaToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("2 media items")
  })

  it("renders a compact gallery with a thumbnail, stable ID, filename, kind, and content type", () => {
    const parsedResult = {
      snapshots: [],
      chat_images: [
        {
          id: "chat_image:3",
          kind: "chat_image",
          filename: "desktop.png",
          content_type: "image/png",
          file_path: "/api/v1/app/chats/12/media/chat_images/3/file"
        }
      ]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    const tile = screen.getByRole("button", { name: "Open desktop.png" })
    expect(within(tile).getByRole("img", { name: "desktop.png" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(within(tile).getByText("desktop.png")).toBeInTheDocument()
    expect(within(tile).getByText("image/png")).toBeInTheDocument()
    expect(within(tile).getByText("image")).toBeInTheDocument()
  })

  it("renders and opens a linked fallback preview for a snapshot with no thumbnail", () => {
    const parsedResult = {
      snapshots: [
        { id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z", whiteboard_url: "/chats/12" }
      ],
      chat_images: []
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    const tile = screen.getByRole("button", { name: "Open Checkout flow" })
    expect(within(tile).getByText("Whiteboard snapshot")).toBeInTheDocument()
    expect(within(tile).getByText("Checkout flow")).toBeInTheDocument()
    expect(within(tile).getByText("2026-09-01T12:00:00Z")).toBeInTheDocument()
    fireEvent.click(tile)
    const dialog = screen.getByRole("dialog", { name: "Checkout flow" })
    expect(within(dialog).getAllByText("Whiteboard snapshot")).toHaveLength(2)
    expect(within(dialog).getByRole("link", { name: "Open whiteboard" })).toHaveAttribute("href", "/chats/12")
  })

  it("uses snapshot thumbnails and absolute image URLs when provided", () => {
    const parsedResult = {
      snapshots: [{ id: "snapshot:2", name: "Rendered board", thumbnail_url: "https://cdn.example/board.png", whiteboard_url: "/chats/2" }],
      images: [{ id: "chat_image:8", name: "remote.png", content_type: "image/png", image_url: "https://cdn.example/remote.png" }]
    }
    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(within(screen.getByRole("button", { name: "Open Rendered board" })).getByRole("img")).toHaveAttribute("src", "https://cdn.example/board.png")
    expect(within(screen.getByRole("button", { name: "Open remote.png" })).getByRole("img")).toHaveAttribute("src", "https://cdn.example/remote.png")
  })

  it("opens a preview modal with full details on click", () => {
    const parsedResult = {
      snapshots: [],
      chat_images: [
        {
          id: "chat_image:3",
          kind: "chat_image",
          filename: "desktop.png",
          content_type: "image/png",
          file_path: "/api/v1/app/chats/12/media/chat_images/3/file"
        }
      ]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)
    fireEvent.click(screen.getByRole("button", { name: "Open desktop.png" }))

    const dialog = screen.getByRole("dialog", { name: "desktop.png" })
    expect(within(dialog).getByText("ID")).toBeInTheDocument()
    expect(within(dialog).getByText("chat_image:3")).toBeInTheDocument()
    expect(within(dialog).getByText("Content type")).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: "Download" })).toHaveAttribute("download")

    fireEvent.click(screen.getByRole("button", { name: "Close media preview" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("is dark-mode safe (uses dark: utility classes on the gallery surfaces)", () => {
    const parsedResult = {
      snapshots: [],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/x/desktop.png" }]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    const tile = screen.getByRole("button", { name: "Open desktop.png" })
    expect(tile.className).toContain("dark:bg-gray-950")
  })

  it("renders an explicit empty state for a well-formed payload with no media", () => {
    const parsedResult = { snapshots: [], chat_images: [], whiteboard_element_count: 0, whiteboard_has_unsaved_content: true }

    expect(listChatMediaToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 media items")
    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No media in this chat yet.")).toBeInTheDocument()
    expect(screen.getByText("0 whiteboard elements")).toBeInTheDocument()
    expect(screen.getByText("Whiteboard has unsaved content:")).toBeInTheDocument()
  })

  it("renders normalized Codex envelopes and provider-prefixed names", () => {
    const envelope = {
      content: [
        {
          type: "text",
          text: JSON.stringify({ snapshots: [], media: [{ id: "chat_image:4", filename: "codex.png", content_type: "image/png", file_path: "/codex.png" }] })
        }
      ]
    }
    const parsedResult = normalizedToolCardParsedResult(envelope)
    render(<>{listChatMediaToolCard.renderExpanded(context({ toolName: "list_chat_media", parsedResult }))}</>)
    expect(screen.getByRole("button", { name: "Open codex.png" })).toBeInTheDocument()
  })

  it("renders error and pending states", () => {
    const { rerender } = render(
      <>{listChatMediaToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: "Media service unavailable" } }))}</>
    )
    expect(screen.getByText("Media service unavailable")).toBeInTheDocument()
    rerender(
      <>
        {listChatMediaToolCard.renderExpanded(
          context({
            livePendingAction: {
              id: 1,
              action: "list",
              state: "pending",
              label: "Waiting for media",
              detail: "Approval required",
              app_confirm_path: "/confirm",
              app_reject_path: "/reject"
            }
          })
        )}
      </>
    )
    expect(screen.getByText("Approval required")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listChatMediaToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: { snapshots: [{ id: "" }], chat_images: "bad" } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
