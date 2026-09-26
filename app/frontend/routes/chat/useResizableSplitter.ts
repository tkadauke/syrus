// Shared drag/click/keyboard state for a resizable, collapsible side pane
// splitter (used by both the Files tab file tree and the Diff tab file
// list). Extracted so the two panes share identical drag-resize, snap-to-
// close/reopen, and keyboard-resize behavior without duplicating the subtle
// drag-vs-click distinguishing state.
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from "react"
import { useEffect, useRef, useState } from "react"
import { storeWorkspacePreference } from "./workspaceTabs"

export type ResizableSplitter = {
  width: number
  collapsed: boolean
  beginResize: (event: ReactMouseEvent<HTMLDivElement>) => void
  toggleCollapsed: () => void
  resizeWithKeyboard: (event: ReactKeyboardEvent<HTMLDivElement>) => void
}

export function useResizableSplitter({
  widthKey,
  collapsedKey,
  initialWidth,
  initialCollapsed,
  defaultWidth,
  snapClosedWidth,
  reopenWidth,
  resizeEdge = "end",
  clampWidth
}: {
  widthKey: string
  collapsedKey: string
  initialWidth: number | (() => number)
  initialCollapsed: boolean | (() => boolean)
  defaultWidth: number
  snapClosedWidth: number
  reopenWidth: number
  resizeEdge?: "start" | "end"
  clampWidth: (width: number) => number
}): ResizableSplitter {
  const [width, setWidth] = useState(initialWidth)
  const [collapsed, setCollapsed] = useState(initialCollapsed)
  const draggedRef = useRef(false)

  useEffect(() => {
    storeWorkspacePreference(widthKey, String(width))
  }, [widthKey, width])

  useEffect(() => {
    storeWorkspacePreference(collapsedKey, String(collapsed))
  }, [collapsedKey, collapsed])

  function beginResize(event: ReactMouseEvent<HTMLDivElement>) {
    event.preventDefault()
    const startX = event.clientX
    const startWidth = collapsed ? 0 : width
    let snappedClosedDuringGesture = collapsed
    draggedRef.current = false

    function resize(moveEvent: MouseEvent) {
      const pointerDelta = resizeEdge === "start" ? startX - moveEvent.clientX : moveEvent.clientX - startX
      const nextWidth = startWidth + pointerDelta
      if (Math.abs(moveEvent.clientX - startX) > 2) draggedRef.current = true

      if (snappedClosedDuringGesture && nextWidth < reopenWidth) {
        setCollapsed(true)
        return
      }

      if (nextWidth < snapClosedWidth) {
        snappedClosedDuringGesture = true
        setCollapsed(true)
        return
      }

      snappedClosedDuringGesture = false
      setCollapsed(false)
      setWidth(clampWidth(nextWidth))
    }

    function stopResize() {
      window.removeEventListener("mousemove", resize)
      window.removeEventListener("mouseup", stopResize)
      window.setTimeout(() => {
        draggedRef.current = false
      }, 0)
    }

    window.addEventListener("mousemove", resize)
    window.addEventListener("mouseup", stopResize)
  }

  function toggleCollapsed() {
    if (draggedRef.current) {
      draggedRef.current = false
      return
    }

    if (collapsed) {
      setCollapsed(false)
      setWidth((current) => clampWidth(current || defaultWidth))
    } else {
      setCollapsed(true)
    }
  }

  function resizeWithKeyboard(event: ReactKeyboardEvent<HTMLDivElement>) {
    if (event.key === "Enter" || event.key === " ") {
      event.preventDefault()
      toggleCollapsed()
      return
    }

    if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return

    event.preventDefault()
    setWidth((current) => {
      const shouldGrow = resizeEdge === "start" ? event.key === "ArrowLeft" : event.key === "ArrowRight"
      const nextWidth = clampWidth(current + (shouldGrow ? 16 : -16))
      if (!shouldGrow && nextWidth === current) {
        setCollapsed(true)
      } else {
        setCollapsed(false)
      }
      return nextWidth
    })
  }

  return { width, collapsed, beginResize, toggleCollapsed, resizeWithKeyboard }
}
