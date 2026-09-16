/**
 * Pure geometry for the dashboard charts. Kept out of the component so the
 * parts that are easy to get quietly wrong -- scales, gaps, tick spacing -- are
 * testable without rendering anything.
 */

export type Scale = { min: number; max: number }

/**
 * The y range a chart should draw.
 *
 * Anchored at zero for counts, because "how far above nothing" is the question
 * those answer and a zero-suppressed count exaggerates noise into drama. The
 * exception is a series whose values are large and tightly clustered, where
 * zero-anchoring flattens the line into uselessness -- the original dashboard
 * drew polling's 21,614 -> 24,124 climb as a horizontal line for exactly that
 * reason. Above that ratio the range is zoomed to the data and the axis labels
 * say so.
 */
export function yScale(values: (number | null)[]): Scale {
  const present = values.filter((value): value is number => value !== null)
  if (present.length === 0) return { min: 0, max: 1 }

  const dataMin = Math.min(...present)
  const dataMax = Math.max(...present)

  if (dataMax === dataMin) return dataMax === 0 ? { min: 0, max: 1 } : { min: 0, max: dataMax * 1.2 }

  const zoomed = dataMin > 0 && (dataMax - dataMin) / dataMax < 0.35
  const min = zoomed ? dataMin - (dataMax - dataMin) * 0.15 : 0
  return { min: Math.max(0, min), max: dataMax + (dataMax - dataMin) * 0.1 }
}

/**
 * Scale across every series in a panel, so lines in one chart are comparable.
 *
 * `hiddenNames` excludes toggled-off series from the range entirely -- the
 * point of hiding a series is usually to stop it from flattening the rest,
 * so the axis has to rescale to what remains rather than just stop drawing
 * the hidden line inside the old range.
 */
export function panelScale(
  series: { name?: string; values: (number | null)[] }[],
  hiddenNames?: ReadonlySet<string>
): Scale {
  const visible = hiddenNames && hiddenNames.size > 0
    ? series.filter((entry) => !entry.name || !hiddenNames.has(entry.name))
    : series
  const all = visible.flatMap((entry) => entry.values)
  return yScale(all)
}

export function yFor(value: number, scale: Scale, height: number) {
  const span = scale.max - scale.min
  if (span <= 0) return height / 2
  return height - ((value - scale.min) / span) * height
}

export function xFor(index: number, count: number, width: number) {
  if (count <= 1) return 0
  return (index / (count - 1)) * width
}

/**
 * SVG path for one series, broken into separate subpaths wherever a bucket has
 * no reading. A line drawn straight across a gap claims we observed something
 * we did not.
 */
export function linePath(
  values: (number | null)[],
  scale: Scale,
  width: number,
  height: number,
  xOffset = 0
) {
  const segments: string[] = []
  let current: string[] = []

  values.forEach((value, index) => {
    if (value === null) {
      if (current.length > 0) segments.push(current.join(" "))
      current = []
      return
    }
    const x = (xFor(index, values.length, width) + xOffset).toFixed(1)
    const y = yFor(value, scale, height).toFixed(1)
    current.push(`${current.length === 0 ? "M" : "L"}${x},${y}`)
  })
  if (current.length > 0) segments.push(current.join(" "))

  // A lone point has no line to draw, so give it a hairline to sit on.
  return segments.map((segment) => (segment.includes("L") ? segment : `${segment} ${segment.slice(1)}`)).join(" ")
}

/** Evenly spaced tick indexes, always including the first and last bucket. */
export function tickIndexes(count: number, desired = 5) {
  if (count <= 1) return [ 0 ]
  const ticks = Math.min(desired, count)
  const step = (count - 1) / (ticks - 1)
  return Array.from({ length: ticks }, (_, i) => Math.round(i * step))
}

/** Rounded axis labels: a chart with 24124.0 on the axis is noise. */
export function formatValue(value: number) {
  if (!Number.isFinite(value)) return "—"
  if (Math.abs(value) >= 100_000) return `${(value / 1000).toFixed(0)}k`
  if (Math.abs(value) >= 10_000) return `${(value / 1000).toFixed(1)}k`
  if (Number.isInteger(value)) return String(value)
  return value.toFixed(Math.abs(value) < 10 ? 1 : 0)
}

/** Seconds render as durations; an age of 24,124 means nothing until it is 6.7h. */
export function formatWithUnit(value: number | null, unit: string) {
  if (value === null) return "—"
  if (unit !== "seconds") return formatValue(value)
  if (value < 90) return `${Math.round(value)}s`
  if (value < 5400) return `${(value / 60).toFixed(0)}m`
  return `${(value / 3600).toFixed(1)}h`
}

export function formatClock(iso: string) {
  const date = new Date(iso)
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })
}

/** "per 5m" reads better on a rate chart than "per 300 seconds". */
export function formatDuration(seconds: number) {
  if (seconds % 3600 === 0) return `${seconds / 3600}h`
  if (seconds % 60 === 0) return `${seconds / 60}m`
  return `${seconds}s`
}
