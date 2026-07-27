import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ImageAnnotationModal } from "./ImageAnnotationModal"

const sourceDataUrl = "data:image/jpeg;base64,c291cmNl"

type MockContext = CanvasRenderingContext2D & {
  snapshots: ImageData[]
}

describe("ImageAnnotationModal", () => {
  let contexts: MockContext[]
  let snapshotId: number

  beforeEach(() => {
    contexts = []
    snapshotId = 0

    vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation(function getContext(this: HTMLCanvasElement) {
      const canvas = this as HTMLCanvasElement & { __mockContext?: MockContext }
      if (!canvas.__mockContext) {
        const context = mockCanvasContext()
        canvas.__mockContext = context
        contexts.push(context)
      }

      return canvas.__mockContext
    })

    vi.spyOn(HTMLCanvasElement.prototype, "toDataURL").mockReturnValue("data:image/png;base64,YW5ub3RhdGVk")
    vi.spyOn(HTMLCanvasElement.prototype, "getBoundingClientRect").mockReturnValue({
      bottom: 80,
      height: 80,
      left: 0,
      right: 100,
      top: 0,
      width: 100,
      x: 0,
      y: 0,
      toJSON: () => ({})
    })

    Object.defineProperty(globalThis, "Image", {
      configurable: true,
      writable: true,
      value: class MockImage {
        naturalWidth = 100
        naturalHeight = 80
        width = 100
        height = 80
        onload: (() => void) | null = null

        set src(_value: string) {
          window.setTimeout(() => this.onload?.(), 0)
        }
      }
    })
  })

  it("selects an annotation tool", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Ellipse" }))

    expect(screen.getByRole("button", { name: "Ellipse" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "false")
  })

  it("selects an annotation color", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("radio", { name: "Blue" }))

    expect(screen.getByRole("radio", { name: "Blue" })).toHaveAttribute("aria-checked", "true")
    expect(screen.getByRole("radio", { name: "Red" })).toHaveAttribute("aria-checked", "false")
  })

  it("composites the annotation into a non-empty PNG data URL", async () => {
    const onDone = vi.fn()
    renderModal({ onDone })
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Done" }))

    expect(onDone).toHaveBeenCalledWith(expect.stringMatching(/^data:image\/png;base64,\S+/))
    expect(contexts[0].drawImage).toHaveBeenCalled()
  })

  it("cancels without returning an annotated image", async () => {
    const onClose = vi.fn()
    const onDone = vi.fn()
    renderModal({ onClose, onDone })
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(onClose).toHaveBeenCalled()
    expect(onDone).not.toHaveBeenCalled()
  })

  it("undo restores the previous overlay canvas snapshot", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 12, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 60, clientY: 50, pointerId: 1 })
    fireEvent.pointerUp(canvas, { clientX: 60, clientY: 50, pointerId: 1 })

    const overlayContext = contexts[1]
    const initialSnapshot = overlayContext.snapshots[0]

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled()
    })
    fireEvent.click(screen.getByRole("button", { name: "Undo" }))

    expect(overlayContext.putImageData).toHaveBeenLastCalledWith(initialSnapshot, 0, 0)
  })

  it("keeps text input visible after placement and commits text on Enter", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Text" }))
    fireEvent.pointerDown(screen.getByLabelText("Annotation canvas"), { clientX: 30, clientY: 32, pointerId: 1 })

    const input = screen.getByPlaceholderText("Type, then press Enter")
    expect(input).toBeVisible()

    fireEvent.change(input, { target: { value: "Review this" } })
    fireEvent.keyDown(input, { key: "Enter" })

    expect(screen.queryByPlaceholderText("Type, then press Enter")).not.toBeInTheDocument()
    expect(contexts[1].fillText).toHaveBeenCalledWith("Review this", 30, 32)
  })

  it("switches tool via keyboard shortcut", async () => {
    renderModal()
    await waitForLoaded()

    const shortcuts: Array<[string, string]> = [
      ["e", "Ellipse"],
      ["l", "Line"],
      ["a", "Arrow"],
      ["p", "Freehand"],
      ["t", "Text"],
      ["r", "Rectangle"]
    ]

    for (const [key, toolName] of shortcuts) {
      fireEvent.keyDown(window, { key })
      expect(screen.getByRole("button", { name: toolName })).toHaveAttribute("aria-pressed", "true")
    }
  })

  it("ignores tool shortcuts when textPlacement is active", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Text" }))
    fireEvent.pointerDown(screen.getByLabelText("Annotation canvas"), { clientX: 30, clientY: 32, pointerId: 1 })
    expect(screen.getByPlaceholderText("Type, then press Enter")).toBeVisible()

    fireEvent.keyDown(window, { key: "r" })
    expect(screen.getByRole("button", { name: "Text" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "false")
  })

  it("ignores tool shortcuts when modifier keys are held", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.keyDown(window, { key: "e", ctrlKey: true })
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "true")

    fireEvent.keyDown(window, { key: "e", metaKey: true })
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "true")

    fireEvent.keyDown(window, { key: "e", altKey: true })
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "true")
  })

  function renderModal(overrides: Partial<Parameters<typeof ImageAnnotationModal>[0]> = {}) {
    const props = {
      dataUrl: sourceDataUrl,
      name: "diagram.jpg",
      onClose: vi.fn(),
      onDone: vi.fn(),
      ...overrides
    }

    return render(<ImageAnnotationModal {...props} />)
  }

  async function waitForLoaded() {
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Done" })).not.toBeDisabled()
    }, { timeout: 5000 })
  }

  function mockCanvasContext(): MockContext {
    const context = {
      snapshots: [],
      beginPath: vi.fn(),
      clearRect: vi.fn(),
      drawImage: vi.fn(),
      ellipse: vi.fn(),
      fillText: vi.fn(),
      getImageData: vi.fn(() => {
        const snapshot = { data: new Uint8ClampedArray([snapshotId++]), height: 80, width: 100 } as ImageData
        context.snapshots.push(snapshot)
        return snapshot
      }),
      lineTo: vi.fn(),
      moveTo: vi.fn(),
      putImageData: vi.fn(),
      rect: vi.fn(),
      stroke: vi.fn(),
      fillStyle: "#000000",
      font: "",
      lineCap: "butt",
      lineJoin: "miter",
      lineWidth: 1,
      strokeStyle: "#000000"
    } as unknown as MockContext

    return context
  }
})
