import { useLayoutEffect } from "react"
import { markStartupMilestone } from "./startupDiagnostics"

export function StartupRenderMarker() {
  useLayoutEffect(() => {
    markStartupMilestone("react_commit")
    const frame = requestAnimationFrame(() => {
      requestAnimationFrame(() => markStartupMilestone("react_post_paint"))
    })
    return () => cancelAnimationFrame(frame)
  }, [])

  return null
}
