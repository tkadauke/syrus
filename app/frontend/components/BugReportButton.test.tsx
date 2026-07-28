import { fireEvent, render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { BugReportButton } from "./BugReportButton"

vi.mock("../api/bugReports", () => ({
  createBugReport: vi.fn().mockResolvedValue({ message: "Bug report queued." })
}))

// html2canvas-pro is unavailable in jsdom; the openDialog catch block handles this
// and the dialog still opens via the finally block.
vi.mock("html2canvas-pro", () => ({
  default: vi.fn().mockRejectedValue(new Error("html2canvas not available in tests"))
}))

function renderButton(props: { position?: "bottom-left" | "bottom-right" } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <BugReportButton context="Test" {...props} />
    </QueryClientProvider>
  )
}

function getBugButton() {
  return screen.getByRole("button", { name: "Report a bug" })
}

describe("BugReportButton", () => {
  beforeEach(() => {
    localStorage.clear()
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 })
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 })
    // jsdom does not implement pointer capture APIs; define no-ops so drag handlers work.
    Object.defineProperty(HTMLElement.prototype, "setPointerCapture", { configurable: true, writable: true, value: vi.fn() })
    Object.defineProperty(HTMLElement.prototype, "releasePointerCapture", { configurable: true, writable: true, value: vi.fn() })
  })

  afterEach(() => {
    // Clean up prototype stubs defined above.
    delete (HTMLElement.prototype as Record<string, unknown>).setPointerCapture
    delete (HTMLElement.prototype as Record<string, unknown>).releasePointerCapture
  })

  it("is always visible — no hidden class", () => {
    renderButton()
    expect(getBugButton()).toBeInTheDocument()
    expect(getBugButton().className).not.toContain("hidden")
  })

  it("defaults to the bottom-right when no saved position exists", () => {
    renderButton()
    const button = getBugButton()
    const left = parseFloat(button.style.left)
    const top = parseFloat(button.style.top)
    // bottom-right: left near right edge, top near bottom
    expect(left).toBeGreaterThan(window.innerWidth / 2)
    expect(top).toBeGreaterThan(window.innerHeight / 2)
  })

  it("defaults to the bottom-left when position='bottom-left' and no saved position", () => {
    renderButton({ position: "bottom-left" })
    const button = getBugButton()
    const left = parseFloat(button.style.left)
    expect(left).toBeLessThan(window.innerWidth / 2)
  })

  it("loads a saved position from localStorage", () => {
    localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 123, top: 456 }))
    renderButton()
    const button = getBugButton()
    expect(button.style.left).toBe("123px")
    expect(button.style.top).toBe("456px")
  })

  it("ignores malformed localStorage data and falls back to default", () => {
    localStorage.setItem("bug-report-button-position", "not-json{{{")
    renderButton()
    const button = getBugButton()
    // Should fall back to default (right side, bottom)
    expect(parseFloat(button.style.left)).toBeGreaterThan(0)
    expect(parseFloat(button.style.top)).toBeGreaterThan(0)
  })

  describe("tap vs drag threshold", () => {
    it("treats displacement below 8px as a tap and opens the dialog", async () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      // Move only 5px — below the 8px threshold
      fireEvent.pointerMove(button, { clientX: 204, clientY: 303, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 204, clientY: 303, pointerId: 1 })

      await screen.findByRole("dialog")
    })

    it("treats displacement of exactly 0px as a tap and opens the dialog", async () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 200, clientY: 300, pointerId: 1 })

      await screen.findByRole("dialog")
    })

    it("treats displacement >= 8px as a drag and does not open the dialog", () => {
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 210, clientY: 300, pointerId: 1 }) // 10px
      fireEvent.pointerUp(button, { clientX: 210, clientY: 300, pointerId: 1 })

      expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    })
  })

  describe("drag — position persistence", () => {
    it("saves the new position to localStorage after a drag", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 250, clientY: 320, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 250, clientY: 320, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      expect(saved!.left).toBeCloseTo(250, 0)
      expect(saved!.top).toBeCloseTo(320, 0)
    })

    it("clamps the saved position so the button stays within the viewport", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      // Drag far beyond the right/bottom edge
      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: 9999, clientY: 9999, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 9999, clientY: 9999, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      // 1024 - 48 = 976; 768 - 48 = 720
      expect(saved!.left).toBeLessThanOrEqual(window.innerWidth - 48)
      expect(saved!.top).toBeLessThanOrEqual(window.innerHeight - 48)
    })

    it("clamps position to the top-left corner when dragged off-screen to the left/top", () => {
      localStorage.setItem("bug-report-button-position", JSON.stringify({ left: 200, top: 300 }))
      renderButton()
      const button = getBugButton()

      fireEvent.pointerDown(button, { clientX: 200, clientY: 300, pointerId: 1 })
      fireEvent.pointerMove(button, { clientX: -9999, clientY: -9999, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: -9999, clientY: -9999, pointerId: 1 })

      const saved = JSON.parse(localStorage.getItem("bug-report-button-position") ?? "null") as {
        left: number
        top: number
      } | null
      expect(saved).not.toBeNull()
      expect(saved!.left).toBeGreaterThanOrEqual(0)
      expect(saved!.top).toBeGreaterThanOrEqual(0)
    })
  })

  describe("keyboard access", () => {
    it("opens the dialog when the button receives a keyboard-triggered click", async () => {
      renderButton()
      const button = getBugButton()

      // A keyboard-triggered click is not preceded by pointer events,
      // so pointerHandledRef stays false and the click handler calls openDialog.
      fireEvent.click(button)

      await screen.findByRole("dialog")
    })

    it("does not open the dialog twice when both a pointer tap and the synthetic click fire", async () => {
      renderButton()
      const button = getBugButton()

      // Simulate a tap followed by the synthetic click the browser fires after pointerup.
      fireEvent.pointerDown(button, { clientX: 100, clientY: 100, pointerId: 1 })
      fireEvent.pointerUp(button, { clientX: 100, clientY: 100, pointerId: 1 })
      // Synthetic click that follows a real pointer tap:
      fireEvent.click(button)

      // Dialog should appear exactly once (not re-opened on the synthetic click).
      const dialogs = await screen.findAllByRole("dialog")
      expect(dialogs).toHaveLength(1)
    })
  })
})
