// Positions Threads rail cards so they line up with their anchors' vertical
// position in the document, Google-Docs style: cards keep document order and
// never overlap, but when anchors cluster too tightly the cards nearest the
// focused/pivot item hold their real position and the rest get pushed away
// (up above the pivot, down below it) to make room.
//
// `computeRailLayout` is deliberately DOM-free and pure so the collision
// math (ordering, non-overlap, pivot behavior) can be unit tested without a
// real layout engine. Callers measure `anchorTop`/`height` from the rendered
// DOM (anchor marker position and card height, both relative to the same
// container) and feed them in here.

export type RailLayoutMeasurement = {
  id: string
  // Desired vertical offset (px) of this card's anchor, relative to the rail
  // container's top edge. `null` means the anchor has no rendered marker to
  // measure (e.g. a point anchor, or a mid-edit render where highlights are
  // momentarily suppressed) -- its desired position is inferred by holding
  // the previous item's resolved position instead of guessing.
  anchorTop: number | null
  height: number
}

export type RailLayout = {
  // Applied as `transform: translateY(stackShift)` on the wrapper around all
  // cards. Can be negative -- that's the allowed "pushed above the top edge"
  // case when a cluster near the top has to make room for a pivot below it.
  stackShift: number
  // Card id -> margin-top (px) to apply between it and the previous card.
  // Never includes the first card (its position is carried entirely by
  // `stackShift`, not a margin, to avoid negative-margin/parent-collapsing
  // surprises on the first child).
  margins: Record<string, number>
}

export const RAIL_CARD_GAP = 12

export function computeRailLayout(items: RailLayoutMeasurement[], pivotId: string | null, gap: number = RAIL_CARD_GAP): RailLayout {
  if (items.length === 0) return { stackShift: 0, margins: {} }

  const anchorTops = resolveAnchorTops(items)
  const pivotIndex = resolvePivotIndex(items, pivotId)
  const positions = new Array<number>(items.length)
  positions[pivotIndex] = anchorTops[pivotIndex]

  for (let i = pivotIndex + 1; i < items.length; i += 1) {
    positions[i] = Math.max(anchorTops[i], positions[i - 1] + items[i - 1].height + gap)
  }
  for (let i = pivotIndex - 1; i >= 0; i -= 1) {
    positions[i] = Math.min(anchorTops[i], positions[i + 1] - items[i].height - gap)
  }

  const margins: Record<string, number> = {}
  for (let i = 1; i < items.length; i += 1) {
    margins[items[i].id] = Math.max(gap, positions[i] - positions[i - 1] - items[i - 1].height)
  }

  return { stackShift: positions[0], margins }
}

function resolvePivotIndex(items: RailLayoutMeasurement[], pivotId: string | null): number {
  if (!pivotId) return 0

  const index = items.findIndex((item) => item.id === pivotId)
  return index === -1 ? 0 : index
}

function resolveAnchorTops(items: RailLayoutMeasurement[]): number[] {
  let previous = 0
  return items.map((item) => {
    previous = item.anchorTop ?? previous
    return previous
  })
}
