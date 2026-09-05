import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
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
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" }]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    const tile = screen.getByRole("button", { name: "Open desktop.png" })
    expect(within(tile).getByRole("img", { name: "desktop.png" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")
    expect(within(tile).getByText("desktop.png")).toBeInTheDocument()
    expect(within(tile).getByText("chat_image:3")).toBeInTheDocument()
    expect(within(tile).getByText("image/png")).toBeInTheDocument()
    expect(within(tile).getByText("image")).toBeInTheDocument()
  })

  it("renders a placeholder tile for a whiteboard snapshot with no thumbnail", () => {
    const parsedResult = {
      snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z" }],
      chat_images: []
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    const tile = screen.getByRole("button", { name: "Open Checkout flow" })
    expect(within(tile).getByText("Snapshot")).toBeInTheDocument()
    expect(within(tile).getByText("Checkout flow")).toBeInTheDocument()
    expect(within(tile).getByText("snapshot:9")).toBeInTheDocument()
  })

  it("opens a preview modal with full details on click", () => {
    const parsedResult = {
      snapshots: [],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" }]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)
    fireEvent.click(screen.getByRole("button", { name: "Open desktop.png" }))

    const dialog = screen.getByRole("dialog", { name: "desktop.png" })
    expect(within(dialog).getByText("ID")).toBeInTheDocument()
    expect(within(dialog).getByText("chat_image:3")).toBeInTheDocument()
    expect(within(dialog).getByText("Content type")).toBeInTheDocument()

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
    const parsedResult = { snapshots: [], chat_images: [] }

    expect(listChatMediaToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("0 media items")
    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)
    expect(screen.getByText("No media in this chat yet.")).toBeInTheDocument()
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
