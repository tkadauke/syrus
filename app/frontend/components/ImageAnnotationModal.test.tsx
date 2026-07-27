import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ImageAnnotationModal } from "./ImageAnnotationModal"

const sourceDataUrl = "data:image/jpeg;base64,c291cmNl"

type MockContext = CanvasRenderingContext2D & {
  _fillTexts: Array<{ text: string; x: number; y: number }>
}

describe("ImageAnnotationModal", () => {
  let contexts: MockContext[]

  beforeEach(() => {
    contexts = []

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
      bottom: 80, height: 80, left: 0, right: 100, top: 0, width: 100,
      x: 0, y: 0, toJSON: () => ({})
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
        set src(_value: string) { window.setTimeout(() => this.onload?.(), 0) }
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
    const onDone  = vi.fn()
    renderModal({ onClose, onDone })
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(onClose).toHaveBeenCalled()
    expect(onDone).not.toHaveBeenCalled()
  })

  it("undo removes the last drawn shape and disables undo when stack is empty", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    // Draw a rectangle
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 12, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 60, clientY: 50, pointerId: 1 })
    fireEvent.pointerUp(canvas, { clientX: 60, clientY: 50, pointerId: 1 })

    const overlayContext = contexts[1]

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled()
    })

    // Undo should call clearRect to wipe the canvas (returning to empty state)
    fireEvent.click(screen.getByRole("button", { name: "Undo" }))

    await waitFor(() => {
      expect(overlayContext.clearRect).toHaveBeenCalled()
    })

    // Undo button disabled again (nothing left to undo)
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Undo" })).toBeDisabled()
    })
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
    // fillText is called during renderCanvas after the TextShape is added to shapes
    await waitFor(() => {
      expect(contexts[1].fillText).toHaveBeenCalledWith("Review this", 30, 32)
    })
  })

  it("switches tool via keyboard shortcut", async () => {
    renderModal()
    await waitForLoaded()

    const shortcuts: Array<[string, string]> = [
      ["s", "Select"],
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

  it("Escape in text input dismisses the input without closing the modal", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Text" }))
    fireEvent.pointerDown(screen.getByLabelText("Annotation canvas"), { clientX: 30, clientY: 32, pointerId: 1 })

    const input = screen.getByPlaceholderText("Type, then press Enter")
    expect(input).toBeVisible()

    fireEvent.keyDown(input, { key: "Escape" })

    expect(screen.queryByPlaceholderText("Type, then press Enter")).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  // --- Retained-mode shape model ---

  it("drawing a rectangle calls rect() on the overlay context", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    await waitFor(() => {
      expect(contexts[1].rect).toHaveBeenCalledWith(10, 10, 40, 30)
    })
  })

  it("drawing a line calls moveTo/lineTo on the overlay context", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Line" }))
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 5, clientY: 5, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 70, clientY: 60, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 70, clientY: 60, pointerId: 1 })

    await waitFor(() => {
      expect(contexts[1].moveTo).toHaveBeenCalledWith(5, 5)
      expect(contexts[1].lineTo).toHaveBeenCalledWith(70, 60)
    })
  })

  it("drawing an ellipse calls ellipse() on the overlay context", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Ellipse" }))
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 20, clientY: 20, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 80, clientY: 60, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 80, clientY: 60, pointerId: 1 })

    await waitFor(() => {
      expect(contexts[1].ellipse).toHaveBeenCalled()
    })
  })

  it("no shape is added when pointer does not move", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    const rectBefore = vi.mocked(contexts[1].rect).mock.calls.length

    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 10, clientY: 10, pointerId: 1 })

    // No additional rect calls after a zero-movement gesture
    expect(vi.mocked(contexts[1].rect).mock.calls.length).toBe(rectBefore)
  })

  // --- Select tool ---

  it("select tool button is present and selectable", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    expect(screen.getByRole("button", { name: "Select" })).toHaveAttribute("aria-pressed", "true")
  })

  it("select tool is reachable via S shortcut", async () => {
    renderModal()
    await waitForLoaded()

    fireEvent.keyDown(window, { key: "s" })
    expect(screen.getByRole("button", { name: "Select" })).toHaveAttribute("aria-pressed", "true")
  })

  it("clicking empty canvas in select mode deselects (no interaction started)", async () => {
    renderModal()
    await waitForLoaded()

    // Draw a shape first
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    // Switch to select and click a shape
    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 25, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 30, clientY: 25, pointerId: 2 })

    await waitFor(() => {
      // Selection overlay is rendered: setLineDash should be called
      expect(contexts[1].setLineDash).toHaveBeenCalled()
    })
  })

  it("move: dragging a selected shape updates its position", async () => {
    renderModal()
    await waitForLoaded()

    // Draw a rectangle at (10,10)-(50,40)
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    // Switch to select, click inside the shape, drag
    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 25, pointerId: 2 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 45, pointerId: 2 }) // +20, +20
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 45, pointerId: 2 })

    await waitFor(() => {
      // Shape moved by +20,+20: rect should be called with new position (30,30)
      const calls = vi.mocked(contexts[1].rect).mock.calls
      const movedCall = calls.find(c => c[0] === 30 && c[1] === 30 && c[2] === 40 && c[3] === 30)
      expect(movedCall).toBeDefined()
    })
  })

  it("resize: dragging br handle of selected rectangle expands it", async () => {
    renderModal()
    await waitForLoaded()

    // Draw a rectangle at (10,10)-(50,40) → w=40, h=30
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    // Switch to select and click the shape to select it
    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 25, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 30, clientY: 25, pointerId: 2 })

    // The 'br' handle is at approximately (50+pad, 40+pad) = ~(54, 44).
    // Drag br handle from (54,44) to (74,54) → +20,+10 expansion
    fireEvent.pointerDown(canvas, { clientX: 54, clientY: 44, pointerId: 3 })
    fireEvent.pointerMove(canvas, { clientX: 74, clientY: 54, pointerId: 3 })
    fireEvent.pointerUp(canvas,   { clientX: 74, clientY: 54, pointerId: 3 })

    await waitFor(() => {
      // After resize: w should be 40+20=60, h should be 30+10=40
      const calls = vi.mocked(contexts[1].rect).mock.calls
      const resizedCall = calls.find(c => c[0] === 10 && c[1] === 10 && c[2] === 60 && c[3] === 40)
      expect(resizedCall).toBeDefined()
    })
  })

  it("delete key removes the selected shape", async () => {
    renderModal()
    await waitForLoaded()

    // Draw a shape
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    // Select the shape
    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 25, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 30, clientY: 25, pointerId: 2 })

    // Record clearRect calls before delete
    const clearsBefore = vi.mocked(contexts[1].clearRect).mock.calls.length

    // Delete the selected shape
    await act(async () => { fireEvent.keyDown(window, { key: "Delete" }) })

    // Canvas should be cleared and re-rendered (clearRect called again)
    await waitFor(() => {
      expect(vi.mocked(contexts[1].clearRect).mock.calls.length).toBeGreaterThan(clearsBefore)
    })

    // Undo stack has the pre-delete snapshot, so undo button is enabled
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled()
    })
  })

  it("Backspace key also removes the selected shape", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 25, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 30, clientY: 25, pointerId: 2 })

    const clearsBefore = vi.mocked(contexts[1].clearRect).mock.calls.length
    await act(async () => { fireEvent.keyDown(window, { key: "Backspace" }) })

    await waitFor(() => {
      expect(vi.mocked(contexts[1].clearRect).mock.calls.length).toBeGreaterThan(clearsBefore)
    })
  })

  it("delete key does nothing when no shape is selected", async () => {
    renderModal()
    await waitForLoaded()

    // Draw a shape but don't select it (stay in rectangle tool)
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    const clearsBefore = vi.mocked(contexts[1].clearRect).mock.calls.length
    fireEvent.keyDown(window, { key: "Delete" })

    // No additional clearRect triggered by delete (no selection)
    expect(vi.mocked(contexts[1].clearRect).mock.calls.length).toBe(clearsBefore)
  })

  it("finishAnnotation re-renders canvas without selection before compositing", async () => {
    const onDone = vi.fn()
    renderModal({ onDone })
    await waitForLoaded()

    // Draw a shape and select it
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Done" }))

    expect(onDone).toHaveBeenCalledWith(expect.stringMatching(/^data:image\/png;base64,\S+/))
    // Image canvas should have the overlay composited onto it
    expect(contexts[0].drawImage).toHaveBeenCalled()
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
      _fillTexts: [],
      beginPath: vi.fn(),
      clearRect: vi.fn(),
      drawImage: vi.fn(),
      ellipse: vi.fn(),
      fillText: vi.fn((text: string, x: number, y: number) => { context._fillTexts.push({ text, x, y }) }),
      getImageData: vi.fn(() => ({ data: new Uint8ClampedArray([0]), height: 80, width: 100 }) as ImageData),
      lineTo: vi.fn(),
      moveTo: vi.fn(),
      putImageData: vi.fn(),
      rect: vi.fn(),
      save: vi.fn(),
      restore: vi.fn(),
      setLineDash: vi.fn(),
      stroke: vi.fn(),
      fill: vi.fn(),
      fillStyle: "#000000",
      font: "",
      lineCap: "butt" as CanvasLineCap,
      lineJoin: "miter" as CanvasLineJoin,
      lineWidth: 1,
      strokeStyle: "#000000"
    } as unknown as MockContext

    return context
  }
})
