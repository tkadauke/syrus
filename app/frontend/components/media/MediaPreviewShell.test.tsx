import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { MediaPreviewShell } from "@app/components/media/MediaPreviewShell"

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
})
