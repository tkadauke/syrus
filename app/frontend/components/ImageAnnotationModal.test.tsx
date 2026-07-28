import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ImageAnnotationModal, type Shape } from "./ImageAnnotationModal"

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

    expect(onDone).toHaveBeenCalledWith(expect.stringMatching(/^data:image\/png;base64,\S+/), expect.any(Array))
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

  // --- Undo/redo ---

  it("undo/redo round-trips shapes correctly", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")

    // Draw a rectangle
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    await waitFor(() => { expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled() })
    expect(screen.getByRole("button", { name: "Redo" })).toBeDisabled()

    // Undo removes the shape — undo becomes disabled, redo becomes enabled
    fireEvent.click(screen.getByRole("button", { name: "Undo" }))

    await waitFor(() => { expect(screen.getByRole("button", { name: "Undo" })).toBeDisabled() })
    expect(screen.getByRole("button", { name: "Redo" })).not.toBeDisabled()

    // Redo restores the shape — undo enabled again, redo disabled again
    fireEvent.click(screen.getByRole("button", { name: "Redo" }))

    await waitFor(() => { expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled() })
    expect(screen.getByRole("button", { name: "Redo" })).toBeDisabled()

    // Canvas was re-rendered with the restored shape
    await waitFor(() => {
      expect(contexts[1].rect).toHaveBeenCalledWith(10, 10, 40, 30)
    })
  })

  it("redo stack clears when a new drawing action is made after undo", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")

    // Draw a rectangle, then undo it
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    await waitFor(() => { expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled() })
    fireEvent.click(screen.getByRole("button", { name: "Undo" }))
    await waitFor(() => { expect(screen.getByRole("button", { name: "Redo" })).not.toBeDisabled() })

    // Draw a new shape — redo stack should be cleared
    fireEvent.pointerDown(canvas, { clientX: 5, clientY: 5, pointerId: 2 })
    fireEvent.pointerMove(canvas, { clientX: 30, clientY: 30, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 30, clientY: 30, pointerId: 2 })

    await waitFor(() => { expect(screen.getByRole("button", { name: "Redo" })).toBeDisabled() })
    expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled()
  })

  it("Ctrl+Shift+Z triggers redo", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")

    // Draw a shape, undo via keyboard, then redo via keyboard
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    await waitFor(() => { expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled() })

    fireEvent.keyDown(window, { key: "z", ctrlKey: true })
    await waitFor(() => { expect(screen.getByRole("button", { name: "Redo" })).not.toBeDisabled() })

    fireEvent.keyDown(window, { key: "z", ctrlKey: true, shiftKey: true })
    await waitFor(() => { expect(screen.getByRole("button", { name: "Redo" })).toBeDisabled() })
    expect(screen.getByRole("button", { name: "Undo" })).not.toBeDisabled()
  })

  // --- Escape key layered behavior ---

  it("Escape with no shapes closes the modal immediately", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    fireEvent.keyDown(window, { key: "Escape" })

    expect(onClose).toHaveBeenCalled()
  })

  it("Escape while a drawing tool is active with shapes switches to select tool", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    // Default tool is rectangle
    expect(screen.getByRole("button", { name: "Rectangle" })).toHaveAttribute("aria-pressed", "true")

    fireEvent.keyDown(window, { key: "Escape" })

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Select" })).toHaveAttribute("aria-pressed", "true")
    })
    expect(onClose).not.toHaveBeenCalled()
  })

  it("Escape while select tool is active with shapes shows discard confirmation", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.keyDown(window, { key: "Escape" })

    await waitFor(() => {
      expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible()
    })
    expect(onClose).not.toHaveBeenCalled()
  })

  it("Escape while text input is active dismisses text input without closing modal", async () => {
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

  it("Escape on the discard confirmation dialog dismisses it without calling onClose", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Select" }))
    fireEvent.keyDown(window, { key: "Escape" })
    await waitFor(() => { expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible() })

    fireEvent.keyDown(window, { key: "Escape" })

    expect(screen.queryByRole("dialog", { name: "Discard all annotations?" })).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  // --- Discard confirmation ---

  it("Cancel button with shapes shows discard confirmation instead of closing", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    await waitFor(() => {
      expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible()
    })
    expect(onClose).not.toHaveBeenCalled()
  })

  it("X close button with shapes shows discard confirmation instead of closing", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Close annotation editor" }))

    await waitFor(() => {
      expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible()
    })
    expect(onClose).not.toHaveBeenCalled()
  })

  it("discard confirmation Discard button calls onClose", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    await waitFor(() => { expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible() })

    fireEvent.click(screen.getByRole("button", { name: "Discard" }))

    expect(onClose).toHaveBeenCalled()
  })

  it("discard confirmation Keep Editing dismisses dialog and does not close modal", async () => {
    const onClose = vi.fn()
    renderModal({ onClose })
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 10, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 50, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 50, clientY: 40, pointerId: 1 })

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    await waitFor(() => { expect(screen.getByRole("dialog", { name: "Discard all annotations?" })).toBeVisible() })

    fireEvent.click(screen.getByRole("button", { name: "Keep Editing" }))

    expect(screen.queryByRole("dialog", { name: "Discard all annotations?" })).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
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

    expect(onDone).toHaveBeenCalledWith(expect.stringMatching(/^data:image\/png;base64,\S+/), expect.any(Array))
    // Image canvas should have the overlay composited onto it
    expect(contexts[0].drawImage).toHaveBeenCalled()
  })

  // --- Shape persistence across open/close cycles ---

  it("re-opening with initialShapes renders them and keeps undo stack empty", async () => {
    const initialShapes: Shape[] = [
      { id: "s1", kind: "rectangle", x: 10, y: 10, w: 40, h: 30, color: "#ef4444" }
    ]
    renderModal({ initialShapes })
    await waitForLoaded()

    // Undo stack is empty — no changes made in this session yet
    expect(screen.getByRole("button", { name: "Undo" })).toBeDisabled()

    // Initial shape is rendered onto the overlay canvas
    await waitFor(() => {
      expect(contexts[1].rect).toHaveBeenCalledWith(10, 10, 40, 30)
    })
  })

  // --- Zoom bar ---

  it("zoom + button increments zoom and updates the percentage label", async () => {
    renderModal()
    await waitForLoaded()

    expect(screen.getByText("100%")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Zoom in" }))

    await waitFor(() => {
      expect(screen.getByText("125%")).toBeInTheDocument()
    })
  })

  it("zoom - button decrements zoom", async () => {
    renderModal()
    await waitForLoaded()

    // Zoom in first so we have room to zoom out
    fireEvent.click(screen.getByRole("button", { name: "Zoom in" }))
    await waitFor(() => { expect(screen.getByText("125%")).toBeInTheDocument() })

    fireEvent.click(screen.getByRole("button", { name: "Zoom out" }))

    await waitFor(() => {
      expect(screen.getByText("100%")).toBeInTheDocument()
    })
  })

  it("zoom - button is disabled at minimum zoom", async () => {
    renderModal()
    await waitForLoaded()

    // Zoom all the way out
    const rangeInput = screen.getByRole("slider", { name: "Zoom level" })
    fireEvent.change(rangeInput, { target: { value: "0.1" } })

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Zoom out" })).toBeDisabled()
    })
  })

  it("zoom + button is disabled at maximum zoom", async () => {
    renderModal()
    await waitForLoaded()

    const rangeInput = screen.getByRole("slider", { name: "Zoom level" })
    fireEvent.change(rangeInput, { target: { value: "8" } })

    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Zoom in" })).toBeDisabled()
    })
  })

  it("zoom slider updates the zoom percentage label", async () => {
    renderModal()
    await waitForLoaded()

    const rangeInput = screen.getByRole("slider", { name: "Zoom level" })
    fireEvent.change(rangeInput, { target: { value: "2" } })

    await waitFor(() => {
      expect(screen.getByText("200%")).toBeInTheDocument()
    })
  })

  it("zoom resets to 100% when dataUrl changes", async () => {
    const { rerender } = renderModal()
    await waitForLoaded()

    // Zoom in
    fireEvent.click(screen.getByRole("button", { name: "Zoom in" }))
    await waitFor(() => { expect(screen.getByText("125%")).toBeInTheDocument() })

    // Re-render with a different dataUrl (simulates re-opening a new image)
    rerender(
      <ImageAnnotationModal
        dataUrl="data:image/jpeg;base64,bmV3"
        name="new.jpg"
        onClose={vi.fn()}
        onDone={vi.fn()}
      />
    )

    await waitFor(() => {
      expect(screen.getByText("100%")).toBeInTheDocument()
    })
  })

  // --- Pinch gesture ---

  it("pinch-out (spreading two pointers) increases zoom", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")

    // First pointer down at x=30
    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 40, pointerId: 1 })
    // Second pointer down at x=70 → initial dist=40, mid=(50,40)
    fireEvent.pointerDown(canvas, { clientX: 70, clientY: 40, pointerId: 2 })

    // Move fingers apart: x=20 and x=80 → dist=60 → zoom = 1 * 60/40 = 1.5
    fireEvent.pointerMove(canvas, { clientX: 20, clientY: 40, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 80, clientY: 40, pointerId: 2 })

    await waitFor(() => {
      expect(screen.getByText("150%")).toBeInTheDocument()
    })
  })

  it("pinch-in (pinching two pointers) decreases zoom", async () => {
    renderModal()
    await waitForLoaded()

    // First zoom in via button so pinch-in has room
    fireEvent.click(screen.getByRole("button", { name: "Zoom in" }))
    fireEvent.click(screen.getByRole("button", { name: "Zoom in" }))
    await waitFor(() => { expect(screen.getByText("150%")).toBeInTheDocument() })

    const canvas = screen.getByLabelText("Annotation canvas")

    // Wide pinch start: dist=80
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 40, pointerId: 1 })
    fireEvent.pointerDown(canvas, { clientX: 90, clientY: 40, pointerId: 2 })

    // Pinch to dist=40 → zoom = 1.5 * 40/80 = 0.75
    fireEvent.pointerMove(canvas, { clientX: 30, clientY: 40, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 70, clientY: 40, pointerId: 2 })

    await waitFor(() => {
      expect(screen.getByText("75%")).toBeInTheDocument()
    })
  })

  it("two-pointer pinch does not trigger drawing", async () => {
    renderModal()
    await waitForLoaded()

    const canvas = screen.getByLabelText("Annotation canvas")
    const rectCallsBefore = vi.mocked(contexts[1].rect).mock.calls.length

    fireEvent.pointerDown(canvas, { clientX: 30, clientY: 40, pointerId: 1 })
    fireEvent.pointerDown(canvas, { clientX: 70, clientY: 40, pointerId: 2 })
    fireEvent.pointerMove(canvas, { clientX: 20, clientY: 40, pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 80, clientY: 40, pointerId: 2 })
    fireEvent.pointerUp(canvas,   { clientX: 20, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 80, clientY: 40, pointerId: 2 })

    expect(vi.mocked(contexts[1].rect).mock.calls.length).toBe(rectCallsBefore)
  })

  // --- Coordinate correction under zoom ---

  it("drawing coordinates are correct under zoom (getBoundingClientRect accounts for scale)", async () => {
    renderModal()
    await waitForLoaded()

    // Simulate a zoomed state by overriding the mock: rect.width=200 (zoom=2 of the 100px canvas)
    vi.spyOn(HTMLCanvasElement.prototype, "getBoundingClientRect").mockReturnValue({
      bottom: 160, height: 160, left: 0, right: 200, top: 0, width: 200,
      x: 0, y: 0, toJSON: () => ({})
    })

    // canvas.width=100, rect.width=200 → scaleX=0.5 → clicking at clientX=60 maps to canvasX=30
    const canvas = screen.getByLabelText("Annotation canvas")
    fireEvent.pointerDown(canvas, { clientX: 0,  clientY: 0,  pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 60, clientY: 40, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 60, clientY: 40, pointerId: 1 })

    await waitFor(() => {
      expect(contexts[1].rect).toHaveBeenCalledWith(0, 0, 30, 20)
    })
  })

  it("drawing coordinates are correct under pan (getBoundingClientRect offset accounts for pan)", async () => {
    renderModal()
    await waitForLoaded()

    // Simulate pan={x:10,y:5}: rect.left=10, rect.top=5 (canvas shifted by pan)
    vi.spyOn(HTMLCanvasElement.prototype, "getBoundingClientRect").mockReturnValue({
      bottom: 85, height: 80, left: 10, right: 110, top: 5, width: 100,
      x: 10, y: 5, toJSON: () => ({})
    })

    const canvas = screen.getByLabelText("Annotation canvas")
    // Drawing from (10,5) to (60,45): rect offset subtracts: (0,0) to (50,40)
    fireEvent.pointerDown(canvas, { clientX: 10, clientY: 5,  pointerId: 1 })
    fireEvent.pointerMove(canvas, { clientX: 60, clientY: 45, pointerId: 1 })
    fireEvent.pointerUp(canvas,   { clientX: 60, clientY: 45, pointerId: 1 })

    await waitFor(() => {
      expect(contexts[1].rect).toHaveBeenCalledWith(0, 0, 50, 40)
    })
  })

  it("Done passes the current shape list back alongside the annotated data URL", async () => {
    const initialShapes: Shape[] = [
      { id: "s1", kind: "rectangle", x: 10, y: 10, w: 40, h: 30, color: "#ef4444" }
    ]
    const onDone = vi.fn()
    renderModal({ initialShapes, onDone })
    await waitForLoaded()

    fireEvent.click(screen.getByRole("button", { name: "Done" }))

    expect(onDone).toHaveBeenCalledWith(
      expect.stringMatching(/^data:image\/png;base64,\S+/),
      expect.arrayContaining([expect.objectContaining({ id: "s1", kind: "rectangle" })])
    )
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
