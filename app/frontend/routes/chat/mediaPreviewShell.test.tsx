import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MediaPreviewShell } from "./mediaPreviewShell"

describe("MediaPreviewShell", () => {
  it("opens a full preview, exposes actions, copies metadata, and closes on Escape", async () => {
    const clipboardWrite = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText: clipboardWrite } })

    render(
      <MediaPreviewShell
        item={{
          title: "settings.png",
          subtitle: "image/png",
          src: "/media/settings.png",
          actions: [
            { label: "Open", href: "/media/settings.png" },
            { label: "Download", href: "/media/settings.png?download=1", download: true },
            { label: "Copy ID", copyValue: "chat_image:3" }
          ],
          meta: [
            { label: "ID", value: "chat_image:3", copyValue: "chat_image:3" },
            { label: "Path", value: "/media/settings.png", copyValue: "/media/settings.png" }
          ]
        }}
        modalLabel="Shared media preview"
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Open settings.png" }))

    expect(screen.getByRole("dialog", { name: "Shared media preview" })).toBeInTheDocument()
    expect(screen.getAllByRole("img", { name: "settings.png" })).toHaveLength(2)
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "/media/settings.png")
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("download")

    fireEvent.click(screen.getAllByRole("button", { name: "Copy ID" })[1])
    expect(clipboardWrite).toHaveBeenCalledWith("chat_image:3")

    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("dialog", { name: "Shared media preview" })).not.toBeInTheDocument()
  })

  it("shows a readable fallback when an image cannot load", () => {
    render(<MediaPreviewShell item={{ title: "broken.png", src: "/missing.png", fallbackLabel: "Image unavailable" }} />)

    fireEvent.error(screen.getByRole("img", { name: "broken.png" }))

    expect(screen.queryByRole("img", { name: "broken.png" })).not.toBeInTheDocument()
    expect(screen.getByText("Image unavailable")).toBeInTheDocument()
  })

  it("opens and downloads data-backed media through a temporary blob URL", () => {
    const createObjectURL = vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:runtime-snapshot")
    const revokeObjectURL = vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)

    const { unmount } = render(
      <MediaPreviewShell
        item={{
          title: "snapshot.png",
          src: "data:image/png;base64,YWJj",
          actions: [
            { label: "Open", href: "data:image/png;base64,YWJj", dataUrlAsBlob: true },
            { label: "Download", href: "data:image/png;base64,YWJj", download: true, dataUrlAsBlob: true }
          ]
        }}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Open snapshot.png" }))
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "blob:runtime-snapshot")
    expect(screen.getByRole("link", { name: "Download" })).toHaveAttribute("href", "blob:runtime-snapshot")
    expect(createObjectURL).toHaveBeenCalledTimes(2)

    unmount()
    expect(revokeObjectURL).toHaveBeenCalledTimes(2)
  })

  it("falls back to the original URL when data-backed media is malformed", () => {
    render(
      <MediaPreviewShell
        item={{
          title: "placeholder.png",
          src: "data:image/png;base64,abc123",
          actions: [{ label: "Open", href: "data:image/png;base64,abc123", dataUrlAsBlob: true }]
        }}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Open placeholder.png" }))
    expect(screen.getByRole("link", { name: "Open" })).toHaveAttribute("href", "data:image/png;base64,abc123")
  })
})
