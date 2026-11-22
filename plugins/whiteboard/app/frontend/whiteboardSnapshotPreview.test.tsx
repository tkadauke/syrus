import { render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { reportHandledError } from "@app/lib/handledErrorReporting"
import { WhiteboardScenePreview } from "./whiteboardSnapshotPreview"

vi.mock("@app/lib/handledErrorReporting", () => ({ reportHandledError: vi.fn() }))
vi.mock("./whiteboardSceneRenderer", () => ({
  convertToExcalidrawElements: vi.fn((elements) => elements),
  exportToSvg: vi.fn().mockRejectedValue(new Error("canvas export failed"))
}))

describe("WhiteboardScenePreview handled errors", () => {
  it("keeps the preview fallback and reports serialization failures", async () => {
    render(<WhiteboardScenePreview item={{ title: "Scene", alt: "Scene preview", src: null }} scene={{ elements: [], appState: {}, files: {} }} />)

    await waitFor(() =>
      expect(reportHandledError).toHaveBeenCalledWith(expect.any(Error), {
        surface: "whiteboard_scene",
        operation: "render_preview",
        stage: "serialize",
        recoverability: "retryable"
      })
    )
    expect(screen.queryByRole("img", { name: "Scene preview" })).not.toBeInTheDocument()
  })
})
