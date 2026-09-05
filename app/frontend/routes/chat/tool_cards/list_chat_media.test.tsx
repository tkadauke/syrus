import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "../../../pluginToolCards"
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

  it("renders a compact gallery with thumbnails, stable ids, filenames, kind, and content type", () => {
    const parsedResult = {
      snapshots: [{ id: "snapshot:9", kind: "snapshot", name: "Checkout flow", element_count: 4, created_at: "2026-09-01T12:00:00Z" }],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" }],
      whiteboard_element_count: 7
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("2 media items")).toBeInTheDocument()
    expect(screen.getByText("7 whiteboard elements")).toBeInTheDocument()

    const imageTile = screen.getByRole("button", { name: "Open desktop.png" })
    expect(imageTile).toHaveClass("dark:bg-gray-950")
    const tooltip = imageTile.getAttribute("title")
    expect(tooltip).toContain("desktop.png")
    expect(tooltip).toContain("chat_image:3")
    expect(tooltip).toContain("image/png")
    expect(within(imageTile).getByRole("img", { name: "desktop.png" })).toHaveAttribute("src", "/api/v1/app/chats/12/media/chat_images/3/file")

    const snapshotTile = screen.getByRole("button", { name: "Open Checkout flow" })
    expect(snapshotTile).toHaveAttribute("title", expect.stringContaining("snapshot:9"))
    expect(within(snapshotTile).getByText("Snapshot")).toBeInTheDocument()
  })

  it("opens a preview overlay on click and closes it", () => {
    const parsedResult = {
      snapshots: [],
      chat_images: [{ id: "chat_image:3", kind: "chat_image", filename: "desktop.png", content_type: "image/png", file_path: "/api/v1/app/chats/12/media/chat_images/3/file" }]
    }

    render(<>{listChatMediaToolCard.renderExpanded(context({ parsedResult }))}</>)

    fireEvent.click(screen.getByRole("button", { name: "Open desktop.png" }))
    expect(screen.getByRole("dialog", { name: "desktop.png" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Close media preview" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("falls back to null for empty media (no snapshots, no images)", () => {
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: { snapshots: [], chat_images: [] } }))).toBeNull()
  })

  it("falls back to null for a malformed payload", () => {
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: { snapshots: [{ id: "" }], chat_images: "bad" } }))).toBeNull()
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
    expect(listChatMediaToolCard.renderExpanded(context({ parsedResult: null }))).toBeNull()
  })
})
