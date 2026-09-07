import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { TooltipCard, clampToViewport } from "./TooltipCard"

describe("clampToViewport", () => {
  it("places the tooltip below-right of the cursor when it fits", () => {
    const position = clampToViewport({ x: 100, y: 100 }, { width: 200, height: 80 }, { width: 1200, height: 800 })

    expect(position).toEqual({ left: 112, top: 112 })
  })

  it("flips to the left of the cursor when the default placement would overflow the right edge", () => {
    const position = clampToViewport({ x: 1180, y: 100 }, { width: 200, height: 80 }, { width: 1200, height: 800 })

    expect(position.left + 200).toBeLessThanOrEqual(1200)
    expect(position.left).toBe(1180 - 12 - 200)
  })

  it("flips above the cursor when the default placement would overflow the bottom edge", () => {
    const position = clampToViewport({ x: 100, y: 780 }, { width: 200, height: 80 }, { width: 1200, height: 800 })

    expect(position.top + 80).toBeLessThanOrEqual(800)
    expect(position.top).toBe(780 - 12 - 80)
  })

  it("clamps to a small edge margin near a corner where flipping would also overflow", () => {
    const position = clampToViewport({ x: 4, y: 4 }, { width: 200, height: 80 }, { width: 1200, height: 800 })

    expect(position.left).toBeGreaterThanOrEqual(8)
    expect(position.top).toBeGreaterThanOrEqual(8)
  })

  it("clamps into the viewport when the tooltip is wider than the viewport itself", () => {
    const position = clampToViewport({ x: 500, y: 10 }, { width: 2000, height: 80 }, { width: 1200, height: 800 })

    expect(position.left).toBe(8)
  })
})

describe("TooltipCard", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  function mockSize(width: number, height: number) {
    vi.spyOn(HTMLDivElement.prototype, "getBoundingClientRect").mockReturnValue({
      width, height, top: 0, left: 0, right: width, bottom: height, x: 0, y: 0, toJSON: () => ({})
    })
  }

  it("keeps the tooltip fully within the viewport when hovering near the right edge", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 })
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 })
    mockSize(320, 96)

    render(<TooltipCard x={1000} y={100}>content</TooltipCard>)

    const tooltip = screen.getByRole("tooltip")
    const left = Number.parseFloat(tooltip.style.left)
    expect(left + 320).toBeLessThanOrEqual(1024)
  })

  it("keeps the tooltip fully within the viewport when hovering near the bottom-right corner", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 })
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 })
    mockSize(320, 96)

    render(<TooltipCard x={1010} y={750}>content</TooltipCard>)

    const tooltip = screen.getByRole("tooltip")
    const left = Number.parseFloat(tooltip.style.left)
    const top = Number.parseFloat(tooltip.style.top)
    expect(left + 320).toBeLessThanOrEqual(1024)
    expect(top + 96).toBeLessThanOrEqual(768)
  })

  it("places the tooltip at the default cursor offset away from any edge", () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 1024 })
    Object.defineProperty(window, "innerHeight", { configurable: true, value: 768 })
    mockSize(320, 96)

    render(<TooltipCard x={100} y={100}>content</TooltipCard>)

    const tooltip = screen.getByRole("tooltip")
    expect(tooltip.style.left).toBe("112px")
    expect(tooltip.style.top).toBe("112px")
  })
})
