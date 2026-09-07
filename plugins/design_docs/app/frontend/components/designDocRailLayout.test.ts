import { describe, expect, it } from "vitest"
import { computeRailLayout, RAIL_CARD_GAP, type RailLayoutMeasurement } from "./designDocRailLayout"

function finalPositions(items: RailLayoutMeasurement[], pivotId: string | null, gap = RAIL_CARD_GAP) {
  const { stackShift, margins } = computeRailLayout(items, pivotId, gap)
  const positions: number[] = []
  items.forEach((item, index) => {
    positions.push(index === 0 ? stackShift : positions[index - 1] + items[index - 1].height + (margins[item.id] ?? 0))
  })
  return positions
}

describe("computeRailLayout", () => {
  it("returns an empty layout for no items", () => {
    expect(computeRailLayout([], null)).toEqual({ stackShift: 0, margins: {} })
  })

  it("aligns a single card exactly to its anchor", () => {
    expect(computeRailLayout([{ id: "a", anchorTop: 120, height: 40 }], null)).toEqual({ stackShift: 120, margins: {} })
  })

  it("keeps cards at their desired position when there is no collision", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: 200, height: 40 },
      { id: "c", anchorTop: 500, height: 40 }
    ]

    expect(finalPositions(items, null)).toEqual([0, 200, 500])
  })

  it("pushes later cards down, in document order, when anchors cluster too tightly", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 50 },
      { id: "b", anchorTop: 10, height: 50 },
      { id: "c", anchorTop: 20, height: 50 }
    ]

    const positions = finalPositions(items, null)
    expect(positions).toEqual([0, 62, 124])
    // Non-overlap and order preserved for every consecutive pair.
    for (let i = 1; i < positions.length; i += 1) {
      expect(positions[i]).toBeGreaterThanOrEqual(positions[i - 1] + items[i - 1].height + RAIL_CARD_GAP)
    }
  })

  it("never reorders cards even under heavy clustering", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 100, height: 60 },
      { id: "b", anchorTop: 102, height: 60 },
      { id: "c", anchorTop: 104, height: 60 },
      { id: "d", anchorTop: 106, height: 60 }
    ]

    const positions = finalPositions(items, null)
    for (let i = 1; i < positions.length; i += 1) {
      expect(positions[i]).toBeGreaterThanOrEqual(positions[i - 1] + items[i - 1].height + RAIL_CARD_GAP)
    }
  })

  it("pins the pivot card exactly to its anchor and pushes neighbors down after it", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: 20, height: 40 },
      { id: "c", anchorTop: 400, height: 40 }
    ]

    const layout = computeRailLayout(items, "b")
    expect(layout.stackShift + items[0].height + layout.margins.b).toBe(20)

    const positions = finalPositions(items, "b")
    expect(positions[1]).toBe(20)
    expect(positions[2]).toBe(400)
  })

  it("can push cards before the pivot above the container's top edge (negative stackShift)", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: 20, height: 40 },
      { id: "c", anchorTop: 400, height: 40 }
    ]

    const layout = computeRailLayout(items, "c")
    expect(layout.stackShift).toBeLessThan(0)

    const positions = finalPositions(items, "c")
    expect(positions[2]).toBe(400)
    expect(positions[1]).toBeLessThanOrEqual(positions[2] - items[1].height - RAIL_CARD_GAP)
    expect(positions[0]).toBeLessThanOrEqual(positions[1] - items[0].height - RAIL_CARD_GAP)
  })

  it("brings a selected card back into exact alignment with its anchor", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: 5, height: 40 },
      { id: "c", anchorTop: 10, height: 40 }
    ]

    const positions = finalPositions(items, "a")
    expect(positions[0]).toBe(0)
  })

  it("falls back to the previous item's resolved position for unmeasured anchors (no rendered marker)", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: null, height: 40 },
      { id: "c", anchorTop: 300, height: 40 }
    ]

    const positions = finalPositions(items, null)
    expect(positions[1]).toBe(positions[0] + items[0].height + RAIL_CARD_GAP)
    expect(positions[2]).toBe(300)
  })

  it("treats an unresolvable pivot id the same as no pivot", () => {
    const items: RailLayoutMeasurement[] = [
      { id: "a", anchorTop: 0, height: 40 },
      { id: "b", anchorTop: 200, height: 40 }
    ]

    expect(computeRailLayout(items, "missing")).toEqual(computeRailLayout(items, null))
  })
})
