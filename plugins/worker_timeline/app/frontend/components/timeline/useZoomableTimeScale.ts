import { scaleTime } from "d3-scale"
import { select } from "d3-selection"
import { zoom as d3zoom, zoomIdentity, type ZoomTransform } from "d3-zoom"
import { useEffect, useMemo, useRef, useState } from "react"
import { CHART_WIDTH } from "./constants"

// Time-axis scaling + pan/zoom gesture handling shared by the macro (worker
// lanes) and micro (Step lanes) chart views. `from`/`to` are ISO8601
// timestamps bounding the chart's time domain.
export function useZoomableTimeScale(from: string, to: string) {
  const axisRef = useRef<HTMLDivElement | null>(null)
  const [transform, setTransform] = useState<ZoomTransform>(zoomIdentity)

  const baseScale = useMemo(
    () => scaleTime().domain([ new Date(from), new Date(to) ]).range([ 0, CHART_WIDTH ]),
    [ from, to ]
  )
  const xScale = useMemo(() => transform.rescaleX(baseScale), [ baseScale, transform ])

  // Bound to the time-axis header only, NOT the scrollable lanes container
  // below it. d3-zoom's default wheel handler calls preventDefault() /
  // stopImmediatePropagation() on any wheel event that would change the
  // horizontal scale -- which is every wheel event once the user has
  // zoomed in at all. Binding it to the same element users scroll
  // vertically to browse lanes would swallow that scroll the moment
  // zooming is used, defeating row virtualization's whole point.
  useEffect(() => {
    const el = axisRef.current
    if (!el) return undefined

    const behavior = d3zoom<HTMLDivElement, unknown>()
      .scaleExtent([ 1, 200 ])
      .translateExtent([ [ 0, 0 ], [ CHART_WIDTH, 0 ] ])
      .extent([ [ 0, 0 ], [ CHART_WIDTH, 0 ] ])
      .on("zoom", (event) => setTransform(event.transform))

    const selection = select(el)
    selection.call(behavior)
    return () => {
      selection.on(".zoom", null)
    }
  }, [])

  return { axisRef, xScale }
}
