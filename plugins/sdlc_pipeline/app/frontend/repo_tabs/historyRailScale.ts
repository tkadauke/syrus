// Geometry for the embedded Pipeline history rail.
//
// The rail is a vertical, independently scrolling timeline with the newest
// moment at the top. Time maps to pixels proportionally (`pixelsPerHour`), but
// two adjacent events are never closer than MIN_TICK_SPACING_PX: dense bursts
// are pushed apart (downwards, toward older time) instead of collapsing into
// overlapping marks. Time landmarks are drawn at the smallest "nice" interval
// whose labels are at least MIN_LABEL_SPACING_PX apart.

export const RAIL_PADDING_PX = 16
/** Smallest vertical distance between two event ticks; keeps each tick individually clickable. */
export const MIN_TICK_SPACING_PX = 14
/** Smallest vertical distance between two time landmarks so labels stay legible. */
export const MIN_LABEL_SPACING_PX = 72

const HOUR_MS = 3_600_000
const LABEL_STEPS_MS = [15 * 60_000, 30 * 60_000, HOUR_MS, 3 * HOUR_MS, 6 * HOUR_MS, 12 * HOUR_MS, 24 * HOUR_MS]
const MAX_LABELS = 400

export function pixelsPerHour(spanMs: number) {
  const days = spanMs / (24 * HOUR_MS)
  if (days <= 2) return 72
  if (days <= 10) return 12
  if (days <= 45) return 4
  return 2
}

export type RailLayout = {
  scale: number // px per ms
  tickY: number[] // px offset from the top of the rail content, aligned with the input ticks
  height: number
  yFor: (timeMs: number) => number
}

export function layoutRail(ticks: string[], fromMs: number, toMs: number): RailLayout {
  const span = Math.max(1, toMs - fromMs)
  const scale = pixelsPerHour(span) / HOUR_MS
  const yFor = (timeMs: number) => RAIL_PADDING_PX + (toMs - Math.min(Math.max(timeMs, fromMs), toMs)) * scale
  const tickY = new Array<number>(ticks.length)
  let previous = -Infinity
  const order = ticks.map((tick, index) => ({ index, at: new Date(tick).getTime() })).sort((a, b) => b.at - a.at)
  order.forEach(({ index, at }) => {
    previous = Math.max(yFor(at), previous + MIN_TICK_SPACING_PX)
    tickY[index] = previous
  })
  const lastTick = tickY.length ? Math.max(...tickY) : 0
  return { scale, tickY, height: Math.ceil(Math.max(RAIL_PADDING_PX * 2 + span * scale, lastTick + RAIL_PADDING_PX)), yFor }
}

export type RailLabel = { at: number; y: number; major: boolean }

/** Time landmarks (newest first). `major` landmarks fall on a local midnight and are rendered as dates. */
export function railLabels(layout: RailLayout, fromMs: number, toMs: number): RailLabel[] {
  const step = LABEL_STEPS_MS.find((candidate) => candidate * layout.scale >= MIN_LABEL_SPACING_PX) ?? LABEL_STEPS_MS[LABEL_STEPS_MS.length - 1]
  const offset = new Date(toMs).getTimezoneOffset() * 60_000
  const labels: RailLabel[] = []
  for (let at = Math.floor((toMs - offset) / step) * step + offset; at >= fromMs && labels.length < MAX_LABELS; at -= step) {
    const date = new Date(at)
    labels.push({ at, y: layout.yFor(at), major: date.getHours() === 0 && date.getMinutes() === 0 })
  }
  return labels
}
