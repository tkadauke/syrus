import { useCallback, useEffect, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from "react"
import { useT } from "../hooks/useT"
import { CloseIcon } from "./CloseIcon"

// --- Shape model ---

type RectShape    = { id: string; kind: "rectangle"; x: number; y: number; w: number; h: number; color: string }
type EllipseShape = { id: string; kind: "ellipse";   x: number; y: number; w: number; h: number; color: string }
type LineShape    = { id: string; kind: "line";       x1: number; y1: number; x2: number; y2: number; color: string }
type ArrowShape   = { id: string; kind: "arrow";      x1: number; y1: number; x2: number; y2: number; color: string }
type FreehandShape = { id: string; kind: "freehand";  points: Array<{ x: number; y: number }>; color: string }
type TextShape    = { id: string; kind: "text";       x: number; y: number; value: string; color: string }
export type Shape = RectShape | EllipseShape | LineShape | ArrowShape | FreehandShape | TextShape

type Tool     = "select" | "rectangle" | "ellipse" | "line" | "arrow" | "freehand" | "text"
type DrawTool = "rectangle" | "ellipse" | "line" | "arrow" | "freehand"

type Point       = { x: number; y: number }
type BoundingBox = { x: number; y: number; w: number; h: number }
type HandlePos   = "tl" | "t" | "tr" | "r" | "br" | "b" | "bl" | "l"

type TextPlacement = Point & { value: string }

type Interaction =
  | { mode: "draw"; kind: DrawTool; start: Point; last: Point; pointerId: number; color: string; freehandPoints: Point[] }
  | { mode: "move";   pointerId: number; shapeId: string; startPointer: Point; lastPointer: Point; startShape: Shape }
  | { mode: "resize"; pointerId: number; shapeId: string; handle: HandlePos; startPointer: Point; lastPointer: Point; startShape: Shape }

// --- Constants ---

const TOOLS: Array<{ id: Tool }> = [
  { id: "select" },
  { id: "rectangle" },
  { id: "ellipse" },
  { id: "line" },
  { id: "arrow" },
  { id: "freehand" },
  { id: "text" }
]

const COLORS = [
  { key: "red",    value: "#ef4444" },
  { key: "blue",   value: "#3b82f6" },
  { key: "yellow", value: "#eab308" },
  { key: "green",  value: "#22c55e" },
  { key: "white",  value: "#ffffff" },
  { key: "black",  value: "#000000" }
]

const TOOL_SHORTCUTS: Record<string, Tool> = {
  s: "select",
  r: "rectangle",
  e: "ellipse",
  l: "line",
  a: "arrow",
  p: "freehand",
  t: "text"
}

const STROKE_WIDTH    = 3
const TEXT_FONT       = "bold 20px sans-serif"
const TEXT_HEIGHT     = 24
const TEXT_CHAR_WIDTH = 12
const MAX_UNDO_STEPS  = 50
const HANDLE_SIZE     = 8
const HANDLE_HIT_RAD  = 7
const SELECTION_PAD   = 4
const HIT_PAD         = 6
const SELECTION_COLOR = "#3b82f6"

const ZOOM_MIN  = 0.1
const ZOOM_MAX  = 8
const ZOOM_STEP = 0.25

let nextShapeId = 0
function makeId() { return `s${++nextShapeId}` }

function clampZoom(z: number) { return Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, z)) }

// --- Geometry helpers ---

function shapeBounds(shape: Shape): BoundingBox {
  switch (shape.kind) {
    case "rectangle":
    case "ellipse":
      return {
        x: Math.min(shape.x, shape.x + shape.w),
        y: Math.min(shape.y, shape.y + shape.h),
        w: Math.abs(shape.w),
        h: Math.abs(shape.h)
      }
    case "line":
    case "arrow":
      return {
        x: Math.min(shape.x1, shape.x2),
        y: Math.min(shape.y1, shape.y2),
        w: Math.abs(shape.x2 - shape.x1),
        h: Math.abs(shape.y2 - shape.y1)
      }
    case "freehand": {
      if (shape.points.length === 0) return { x: 0, y: 0, w: 0, h: 0 }
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
      for (const p of shape.points) {
        if (p.x < minX) minX = p.x
        if (p.y < minY) minY = p.y
        if (p.x > maxX) maxX = p.x
        if (p.y > maxY) maxY = p.y
      }
      return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
    }
    case "text":
      return { x: shape.x, y: shape.y - TEXT_HEIGHT, w: shape.value.length * TEXT_CHAR_WIDTH, h: TEXT_HEIGHT }
  }
}

function hitTest(shape: Shape, point: Point): boolean {
  const b = shapeBounds(shape)
  return (
    point.x >= b.x - HIT_PAD && point.x <= b.x + b.w + HIT_PAD &&
    point.y >= b.y - HIT_PAD && point.y <= b.y + b.h + HIT_PAD
  )
}

function getHandles(bounds: BoundingBox): Array<{ pos: HandlePos; x: number; y: number }> {
  const { x, y, w, h } = bounds
  return [
    { pos: "tl", x,         y         },
    { pos: "t",  x: x+w/2,  y         },
    { pos: "tr", x: x+w,    y         },
    { pos: "r",  x: x+w,    y: y+h/2  },
    { pos: "br", x: x+w,    y: y+h    },
    { pos: "b",  x: x+w/2,  y: y+h    },
    { pos: "bl", x,         y: y+h    },
    { pos: "l",  x,         y: y+h/2  }
  ]
}

function hitHandle(handle: { x: number; y: number }, point: Point): boolean {
  return Math.abs(point.x - handle.x) <= HANDLE_HIT_RAD && Math.abs(point.y - handle.y) <= HANDLE_HIT_RAD
}

function applyMove(startShape: Shape, dx: number, dy: number): Shape {
  switch (startShape.kind) {
    case "rectangle":
    case "ellipse":
      return { ...startShape, x: startShape.x + dx, y: startShape.y + dy }
    case "line":
    case "arrow":
      return { ...startShape, x1: startShape.x1 + dx, y1: startShape.y1 + dy, x2: startShape.x2 + dx, y2: startShape.y2 + dy }
    case "freehand":
      return { ...startShape, points: startShape.points.map(p => ({ x: p.x + dx, y: p.y + dy })) }
    case "text":
      return { ...startShape, x: startShape.x + dx, y: startShape.y + dy }
  }
}

function applyResize(startShape: Shape, handle: HandlePos, dx: number, dy: number): Shape {
  switch (startShape.kind) {
    case "rectangle":
    case "ellipse": {
      // Work with normalized bounds then store as x,y,w,h
      const b = shapeBounds(startShape)
      let { x, y, w, h } = b
      if (handle.includes("l")) { x += dx; w -= dx }
      if (handle.includes("r")) { w += dx }
      if (handle.includes("t")) { y += dy; h -= dy }
      if (handle.includes("b")) { h += dy }
      return { ...startShape, x, y, w, h }
    }
    case "line":
    case "arrow": {
      // Map handles to endpoints based on which endpoint is at that boundary
      let { x1, y1, x2, y2 } = startShape
      const leftIsX1  = startShape.x1 <= startShape.x2
      const topIsY1   = startShape.y1 <= startShape.y2
      if (handle.includes("l")) { if (leftIsX1) x1 += dx; else x2 += dx }
      if (handle.includes("r")) { if (leftIsX1) x2 += dx; else x1 += dx }
      if (handle.includes("t")) { if (topIsY1)  y1 += dy; else y2 += dy }
      if (handle.includes("b")) { if (topIsY1)  y2 += dy; else y1 += dy }
      return { ...startShape, x1, y1, x2, y2 }
    }
    case "text":
      // Text resize acts as move (no meaningful resize)
      return { ...startShape, x: startShape.x + dx, y: startShape.y + dy }
    case "freehand":
      return startShape
  }
}

// --- Canvas rendering ---

function configureStroke(context: CanvasRenderingContext2D, color: string) {
  context.strokeStyle = color
  context.fillStyle   = color
  context.lineWidth   = STROKE_WIDTH
  context.lineCap     = "round"
  context.lineJoin    = "round"
  context.font        = TEXT_FONT
}

function renderArrowHead(context: CanvasRenderingContext2D, start: Point, end: Point) {
  const angle = Math.atan2(end.y - start.y, end.x - start.x)
  const headLength = 16
  context.beginPath()
  context.moveTo(end.x, end.y)
  context.lineTo(end.x - headLength * Math.cos(angle - Math.PI / 6), end.y - headLength * Math.sin(angle - Math.PI / 6))
  context.moveTo(end.x, end.y)
  context.lineTo(end.x - headLength * Math.cos(angle + Math.PI / 6), end.y - headLength * Math.sin(angle + Math.PI / 6))
  context.stroke()
}

function renderShape(shape: Shape, context: CanvasRenderingContext2D) {
  configureStroke(context, shape.color)
  switch (shape.kind) {
    case "rectangle":
      context.beginPath()
      context.rect(shape.x, shape.y, shape.w, shape.h)
      context.stroke()
      break
    case "ellipse":
      context.beginPath()
      context.ellipse(shape.x + shape.w / 2, shape.y + shape.h / 2, Math.abs(shape.w / 2), Math.abs(shape.h / 2), 0, 0, Math.PI * 2)
      context.stroke()
      break
    case "line":
      context.beginPath()
      context.moveTo(shape.x1, shape.y1)
      context.lineTo(shape.x2, shape.y2)
      context.stroke()
      break
    case "arrow":
      context.beginPath()
      context.moveTo(shape.x1, shape.y1)
      context.lineTo(shape.x2, shape.y2)
      context.stroke()
      renderArrowHead(context, { x: shape.x1, y: shape.y1 }, { x: shape.x2, y: shape.y2 })
      break
    case "freehand":
      if (shape.points.length < 2) break
      context.beginPath()
      context.moveTo(shape.points[0].x, shape.points[0].y)
      for (let i = 1; i < shape.points.length; i++) {
        context.lineTo(shape.points[i].x, shape.points[i].y)
      }
      context.stroke()
      break
    case "text":
      context.fillText(shape.value, shape.x, shape.y)
      break
  }
}

function renderSelectionOverlay(shape: Shape, context: CanvasRenderingContext2D) {
  const b = shapeBounds(shape)
  const bx = b.x - SELECTION_PAD
  const by = b.y - SELECTION_PAD
  const bw = b.w + SELECTION_PAD * 2
  const bh = b.h + SELECTION_PAD * 2

  context.save()
  context.strokeStyle = SELECTION_COLOR
  context.lineWidth   = 1.5
  context.setLineDash([4, 3])
  context.beginPath()
  context.rect(bx, by, bw, bh)
  context.stroke()
  context.setLineDash([])

  if (shape.kind !== "freehand") {
    const handles = getHandles({ x: bx, y: by, w: bw, h: bh })
    context.fillStyle   = "white"
    context.strokeStyle = SELECTION_COLOR
    context.lineWidth   = 1.5
    for (const h of handles) {
      context.beginPath()
      context.rect(h.x - HANDLE_SIZE / 2, h.y - HANDLE_SIZE / 2, HANDLE_SIZE, HANDLE_SIZE)
      context.fill()
      context.stroke()
    }
  }

  context.restore()
}

function renderCanvas(
  shapes: Shape[],
  selectedShapeId: string | null,
  context: CanvasRenderingContext2D,
  canvas: HTMLCanvasElement
) {
  context.clearRect(0, 0, canvas.width, canvas.height)
  for (const shape of shapes) renderShape(shape, context)
  if (selectedShapeId) {
    const sel = shapes.find(s => s.id === selectedShapeId)
    if (sel) renderSelectionOverlay(sel, context)
  }
}

function makePreviewShape(kind: DrawTool, start: Point, end: Point, color: string, points: Point[]): Shape {
  switch (kind) {
    case "rectangle": return { id: "__preview__", kind, x: start.x, y: start.y, w: end.x - start.x, h: end.y - start.y, color }
    case "ellipse":   return { id: "__preview__", kind, x: start.x, y: start.y, w: end.x - start.x, h: end.y - start.y, color }
    case "line":      return { id: "__preview__", kind, x1: start.x, y1: start.y, x2: end.x, y2: end.y, color }
    case "arrow":     return { id: "__preview__", kind, x1: start.x, y1: start.y, x2: end.x, y2: end.y, color }
    case "freehand":  return { id: "__preview__", kind, points: [...points], color }
  }
}

// --- Component ---

export function ImageAnnotationModal({
  dataUrl, name, initialShapes, originalDataUrl, onDone, onClose
}: {
  dataUrl: string; name: string; initialShapes?: Shape[]; originalDataUrl?: string
  onDone: (annotatedDataUrl: string, shapes: Shape[]) => void; onClose: () => void
}) {
  const { t } = useT("common")
  const imageCanvasRef   = useRef<HTMLCanvasElement | null>(null)
  const overlayCanvasRef = useRef<HTMLCanvasElement | null>(null)
  const pastRef          = useRef<Shape[][]>([])
  const futureRef        = useRef<Shape[][]>([])
  const interactionRef   = useRef<Interaction | null>(null)
  const shapesRef        = useRef<Shape[]>([])
  // Captured at mount; stable ref avoids adding initialShapes to the image-load effect deps
  const initialShapesRef = useRef<Shape[]>(initialShapes ?? [])

  // Zoom / pan refs (kept in sync with state for use in non-React callbacks)
  const zoomRef           = useRef(1)
  const panRef            = useRef<Point>({ x: 0, y: 0 })
  const isSpaceRef        = useRef(false)
  const activePointersRef = useRef<Map<number, Point>>(new Map())
  const pinchRef          = useRef<{
    startZoom: number; startDist: number
    startMidClient: Point; startPan: Point; containerOrigin: Point
  } | null>(null)
  const isPanDragRef      = useRef<{ startClient: Point; startPan: Point; pointerId: number } | null>(null)

  const [tool,              setTool]              = useState<Tool>("rectangle")
  const [color,             setColor]             = useState(COLORS[0].value)
  const [imageSize,         setImageSize]         = useState<{ width: number; height: number } | null>(null)
  const [undoCount,         setUndoCount]         = useState(0)
  const [redoCount,         setRedoCount]         = useState(0)
  const [textPlacement,     setTextPlacement]     = useState<TextPlacement | null>(null)
  const [shapes,            setShapes]            = useState<Shape[]>([])
  const [selectedShapeId,   setSelectedShapeId]   = useState<string | null>(null)
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false)
  const [zoom,              setZoom]              = useState(1)
  const [pan,               setPan]               = useState<Point>({ x: 0, y: 0 })
  const [isPanning,         setIsPanning]         = useState(false)
  const [isPanDragging,     setIsPanDragging]     = useState(false)

  // Keep shapesRef in sync for use in event handlers without closure staleness
  useEffect(() => { shapesRef.current = shapes }, [shapes])

  // Keep zoom/pan refs in sync with state
  useEffect(() => { zoomRef.current = zoom }, [zoom])
  useEffect(() => { panRef.current = pan },   [pan])

  const requestClose = useCallback(() => {
    if (shapesRef.current.length > 0) {
      setShowDiscardConfirm(true)
    } else {
      onClose()
    }
  }, [onClose])

  const syncHistoryCounts = useCallback(() => {
    setUndoCount(pastRef.current.length)
    setRedoCount(futureRef.current.length)
  }, [])

  // Push current shapes onto past stack before a change; clears redo future
  const pushUndo = useCallback((current: Shape[]) => {
    pastRef.current = [...pastRef.current.slice(-(MAX_UNDO_STEPS - 1)), [...current]]
    futureRef.current = []
    syncHistoryCounts()
  }, [syncHistoryCounts])

  const undo = useCallback(() => {
    if (pastRef.current.length === 0) return
    const previous = pastRef.current[pastRef.current.length - 1]
    pastRef.current = pastRef.current.slice(0, -1)
    futureRef.current = [...futureRef.current, [...shapesRef.current]]
    setShapes(previous)
    setSelectedShapeId(null)
    syncHistoryCounts()
  }, [syncHistoryCounts])

  const redo = useCallback(() => {
    if (futureRef.current.length === 0) return
    const next = futureRef.current[futureRef.current.length - 1]
    futureRef.current = futureRef.current.slice(0, -1)
    pastRef.current = [...pastRef.current.slice(-(MAX_UNDO_STEPS - 1)), [...shapesRef.current]]
    setShapes(next)
    setSelectedShapeId(null)
    syncHistoryCounts()
  }, [syncHistoryCounts])

  // Re-render overlay canvas whenever shapes or selection changes
  useEffect(() => {
    if (!imageSize) return
    const canvas  = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!canvas || !context) return
    renderCanvas(shapes, selectedShapeId, context, canvas)
  }, [shapes, selectedShapeId, imageSize])

  // Load image onto image canvas; prefer originalDataUrl when re-opening an annotated attachment
  const baseImageUrl = originalDataUrl ?? dataUrl
  useEffect(() => {
    let cancelled = false
    const image = new Image()
    image.onload = () => {
      if (cancelled) return
      const width  = image.naturalWidth  || image.width
      const height = image.naturalHeight || image.height
      const imageCanvas   = imageCanvasRef.current
      const overlayCanvas = overlayCanvasRef.current
      const imageContext  = imageCanvas?.getContext("2d")
      const overlayContext = overlayCanvas?.getContext("2d")
      if (!width || !height || !imageCanvas || !overlayCanvas || !imageContext || !overlayContext) return

      imageCanvas.width    = width
      imageCanvas.height   = height
      overlayCanvas.width  = width
      overlayCanvas.height = height
      imageContext.clearRect(0, 0, width, height)
      imageContext.drawImage(image, 0, 0, width, height)
      overlayContext.clearRect(0, 0, width, height)
      pastRef.current = []
      futureRef.current = []
      setShapes(initialShapesRef.current)
      setImageSize({ width, height })
      setZoom(1)
      setPan({ x: 0, y: 0 })
      syncHistoryCounts()
    }
    image.src = baseImageUrl
    return () => { cancelled = true }
  }, [baseImageUrl, syncHistoryCounts])

  // Keyboard shortcuts
  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      // Space bar: enter pan mode
      if (event.code === "Space" && !textPlacement) {
        event.preventDefault()
        isSpaceRef.current = true
        setIsPanning(true)
        return
      }

      if (event.key === "Escape") {
        // Text input handles its own Escape via handleTextKeyDown; guard here prevents double-close.
        if (textPlacement) return
        if (showDiscardConfirm) { setShowDiscardConfirm(false); return }
        const hasShapes = shapesRef.current.length > 0
        if (hasShapes && tool !== "select") { setTool("select"); return }
        if (hasShapes) { setShowDiscardConfirm(true); return }
        onClose()
        return
      }

      if (event.key.toLowerCase() === "z" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        if (event.shiftKey) { redo() } else { undo() }
        return
      }

      // Delete selected shape
      if ((event.key === "Delete" || event.key === "Backspace") && !textPlacement && selectedShapeId) {
        event.preventDefault()
        const prev = shapesRef.current
        pushUndo(prev)
        setShapes(prev.filter(s => s.id !== selectedShapeId))
        setSelectedShapeId(null)
        return
      }

      // Delete selected shape
      if ((event.key === "Delete" || event.key === "Backspace") && !textPlacement && selectedShapeId) {
        event.preventDefault()
        const prev = shapesRef.current
        pushUndo(prev)
        setShapes(prev.filter(s => s.id !== selectedShapeId))
        setSelectedShapeId(null)
        return
      }

      if (!textPlacement && !event.metaKey && !event.ctrlKey && !event.altKey) {
        const mapped = TOOL_SHORTCUTS[event.key.toLowerCase()]
        if (mapped) setTool(mapped)
      }
    }

    const onKeyUp = (event: globalThis.KeyboardEvent) => {
      if (event.code === "Space") {
        isSpaceRef.current = false
        setIsPanning(false)
        setIsPanDragging(false)
        isPanDragRef.current = null
      }
    }

    window.addEventListener("keydown", onKeyDown)
    window.addEventListener("keyup", onKeyUp)
    return () => {
      window.removeEventListener("keydown", onKeyDown)
      window.removeEventListener("keyup", onKeyUp)
    }
  }, [onClose, textPlacement, undo, redo, selectedShapeId, pushUndo, tool, showDiscardConfirm])

  // canvasPoint: converts pointer client coords to canvas pixel coords.
  // In real browsers, getBoundingClientRect accounts for the CSS transform on the parent wrapper,
  // so (clientX - rect.left) * (canvas.width / rect.width) gives correct canvas coords at any zoom/pan.
  function canvasPoint(event: ReactPointerEvent<HTMLCanvasElement>): Point {
    const canvas = event.currentTarget
    const rect   = canvas.getBoundingClientRect()
    const scaleX = rect.width  ? canvas.width  / rect.width  : 1
    const scaleY = rect.height ? canvas.height / rect.height : 1
    return {
      x: Math.max(0, Math.min(canvas.width,  (event.clientX - rect.left) * scaleX)),
      y: Math.max(0, Math.min(canvas.height, (event.clientY - rect.top)  * scaleY))
    }
  }

  function handlePointerDown(event: ReactPointerEvent<HTMLCanvasElement>) {
    // Track every pointer that touches the canvas
    activePointersRef.current.set(event.pointerId, { x: event.clientX, y: event.clientY })

    // Second pointer: start pinch gesture
    if (activePointersRef.current.size === 2) {
      const [p1, p2] = Array.from(activePointersRef.current.values())
      const dist = Math.hypot(p2.x - p1.x, p2.y - p1.y)
      const midClient = { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 }
      // containerOrigin = canvas screen pos minus pan (the "zero pan" anchor)
      const rect = overlayCanvasRef.current?.getBoundingClientRect()
      const containerOrigin = {
        x: rect ? rect.left - panRef.current.x : 0,
        y: rect ? rect.top  - panRef.current.y : 0
      }
      pinchRef.current = {
        startZoom: zoomRef.current, startDist: dist,
        startMidClient: midClient, startPan: { ...panRef.current }, containerOrigin
      }
      // Cancel any in-progress drawing/pan-drag so only pinch runs
      interactionRef.current = null
      isPanDragRef.current   = null
      setIsPanDragging(false)
      event.currentTarget.setPointerCapture?.(event.pointerId)
      return
    }

    if (!imageSize) return
    const canvas  = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!canvas || !context) return

    // Space+drag: pan the canvas
    if (isSpaceRef.current) {
      isPanDragRef.current = {
        startClient: { x: event.clientX, y: event.clientY },
        startPan: { ...panRef.current },
        pointerId: event.pointerId
      }
      setIsPanDragging(true)
      event.currentTarget.setPointerCapture?.(event.pointerId)
      return
    }

    const point = canvasPoint(event)

    if (tool === "text") {
      setTextPlacement({ ...point, value: "" })
      return
    }

    if (tool === "select") {
      const currentShapes = shapesRef.current

      // Check if clicking on a resize handle of the selected shape
      if (selectedShapeId) {
        const sel = currentShapes.find(s => s.id === selectedShapeId)
        if (sel && sel.kind !== "freehand") {
          const b = shapeBounds(sel)
          const paddedBounds = { x: b.x - SELECTION_PAD, y: b.y - SELECTION_PAD, w: b.w + SELECTION_PAD * 2, h: b.h + SELECTION_PAD * 2 }
          for (const handle of getHandles(paddedBounds)) {
            if (hitHandle(handle, point)) {
              event.currentTarget.setPointerCapture?.(event.pointerId)
              interactionRef.current = {
                mode: "resize", pointerId: event.pointerId,
                shapeId: selectedShapeId, handle: handle.pos,
                startPointer: point, lastPointer: point, startShape: sel
              }
              return
            }
          }
        }
      }

      // Hit-test shapes from top (last) to bottom
      for (let i = currentShapes.length - 1; i >= 0; i--) {
        const shape = currentShapes[i]
        if (hitTest(shape, point)) {
          setSelectedShapeId(shape.id)
          event.currentTarget.setPointerCapture?.(event.pointerId)
          interactionRef.current = {
            mode: "move", pointerId: event.pointerId,
            shapeId: shape.id, startPointer: point, lastPointer: point, startShape: shape
          }
          return
        }
      }

      // Clicked empty space: deselect
      setSelectedShapeId(null)
      return
    }

    // Drawing tools
    event.currentTarget.setPointerCapture?.(event.pointerId)
    const drawTool = tool as DrawTool
    interactionRef.current = {
      mode: "draw", kind: drawTool,
      start: point, last: point, pointerId: event.pointerId,
      color, freehandPoints: drawTool === "freehand" ? [point] : []
    }
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLCanvasElement>) {
    // Update tracked pointer position
    if (activePointersRef.current.has(event.pointerId)) {
      activePointersRef.current.set(event.pointerId, { x: event.clientX, y: event.clientY })
    }

    // Pinch: two-finger zoom + pan
    if (pinchRef.current && activePointersRef.current.size >= 2) {
      const pinch = pinchRef.current
      const [p1, p2] = Array.from(activePointersRef.current.values())
      const dist    = Math.hypot(p2.x - p1.x, p2.y - p1.y)
      const newZoom = clampZoom(pinch.startZoom * (dist / pinch.startDist))
      const scale   = newZoom / pinch.startZoom
      // Adjust pan so the midpoint of the pinch stays fixed on screen.
      // M = midpoint offset from the canvas container origin.
      const M = {
        x: pinch.startMidClient.x - pinch.containerOrigin.x,
        y: pinch.startMidClient.y - pinch.containerOrigin.y
      }
      const newPan = {
        x: M.x - (M.x - pinch.startPan.x) * scale,
        y: M.y - (M.y - pinch.startPan.y) * scale
      }
      setZoom(newZoom)
      setPan(newPan)
      return
    }

    // Space+drag pan
    if (isPanDragRef.current?.pointerId === event.pointerId) {
      const { startClient, startPan } = isPanDragRef.current
      setPan({
        x: startPan.x + event.clientX - startClient.x,
        y: startPan.y + event.clientY - startClient.y
      })
      return
    }

    const interaction = interactionRef.current
    const canvas  = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!interaction || !canvas || !context) return

    const point = canvasPoint(event)
    const current = shapesRef.current

    if (interaction.mode === "draw") {
      if (interaction.kind === "freehand") {
        interaction.freehandPoints.push(point)
      }
      interaction.last = point
      const preview = makePreviewShape(interaction.kind, interaction.start, point, interaction.color, interaction.freehandPoints)
      renderCanvas([...current, preview], selectedShapeId, context, canvas)
      return
    }

    const dx = point.x - interaction.startPointer.x
    const dy = point.y - interaction.startPointer.y
    interaction.lastPointer = point

    if (interaction.mode === "move") {
      const updated = applyMove(interaction.startShape, dx, dy)
      renderCanvas(current.map(s => s.id === interaction.shapeId ? updated : s), interaction.shapeId, context, canvas)
      return
    }

    if (interaction.mode === "resize") {
      const updated = applyResize(interaction.startShape, interaction.handle, dx, dy)
      renderCanvas(current.map(s => s.id === interaction.shapeId ? updated : s), interaction.shapeId, context, canvas)
    }
  }

  function handlePointerUp(event: ReactPointerEvent<HTMLCanvasElement>) {
    activePointersRef.current.delete(event.pointerId)

    if (event.currentTarget.hasPointerCapture?.(event.pointerId)) {
      event.currentTarget.releasePointerCapture(event.pointerId)
    }

    // Pinch ended (one finger lifted)
    if (pinchRef.current) {
      if (activePointersRef.current.size < 2) {
        pinchRef.current = null
      }
      return
    }

    // Pan drag ended
    if (isPanDragRef.current?.pointerId === event.pointerId) {
      isPanDragRef.current = null
      setIsPanDragging(false)
      return
    }

    const interaction = interactionRef.current
    if (!interaction) return

    interactionRef.current = null

    if (interaction.mode === "draw") {
      const moved = interaction.start.x !== interaction.last.x || interaction.start.y !== interaction.last.y
      if (!moved) return
      const newShape: Shape = {
        ...makePreviewShape(interaction.kind, interaction.start, interaction.last, interaction.color, interaction.freehandPoints),
        id: makeId()
      }
      const prev = shapesRef.current
      pushUndo(prev)
      setShapes([...prev, newShape])
      return
    }

    const dx = interaction.lastPointer.x - interaction.startPointer.x
    const dy = interaction.lastPointer.y - interaction.startPointer.y
    if (dx === 0 && dy === 0) return

    const prev = shapesRef.current

    if (interaction.mode === "move") {
      const updated = applyMove(interaction.startShape, dx, dy)
      pushUndo(prev)
      setShapes(prev.map(s => s.id === interaction.shapeId ? updated : s))
    }

    if (interaction.mode === "resize") {
      const updated = applyResize(interaction.startShape, interaction.handle, dx, dy)
      pushUndo(prev)
      setShapes(prev.map(s => s.id === interaction.shapeId ? updated : s))
    }
  }

  function commitText() {
    if (!textPlacement) return
    const value = textPlacement.value.trim()
    if (!value) { setTextPlacement(null); return }

    const newShape: TextShape = { id: makeId(), kind: "text", x: textPlacement.x, y: textPlacement.y, value, color }
    const prev = shapesRef.current
    pushUndo(prev)
    setShapes([...prev, newShape])
    setTextPlacement(null)
  }

  function handleTextKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Enter") {
      event.preventDefault()
      commitText()
    }

    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      setTextPlacement(null)
    }
  }

  function finishAnnotation() {
    const imageCanvas   = imageCanvasRef.current
    const overlayCanvas = overlayCanvasRef.current
    const imageContext  = imageCanvas?.getContext("2d")
    const overlayContext = overlayCanvas?.getContext("2d")
    if (!imageCanvas || !overlayCanvas || !imageContext || !overlayContext) return

    // Re-render without selection overlay before compositing
    renderCanvas(shapes, null, overlayContext, overlayCanvas)
    imageContext.drawImage(overlayCanvas, 0, 0)
    onDone(imageCanvas.toDataURL("image/png"), shapesRef.current)
  }

  function changeZoom(delta: number) {
    setZoom(z => clampZoom(z + delta))
  }

  const canvasStyle    = imageSize ? { aspectRatio: `${imageSize.width} / ${imageSize.height}` } : undefined
  const wrapperTransform = `scale(${zoom}) translate(${pan.x / zoom}px, ${pan.y / zoom}px)`
  const overlayCursor  = isPanDragging ? "grabbing" : isPanning ? "grab" : undefined
  const inputStyle     = textPlacement && imageSize ? {
    left: `${(textPlacement.x / imageSize.width)  * 100}%`,
    top:  `${(textPlacement.y / imageSize.height) * 100}%`,
    color
  } : undefined

  return (
    <div className="fixed inset-0 z-40 flex flex-col bg-gray-950/80 p-3 text-gray-900 dark:text-gray-100" role="presentation">
      {showDiscardConfirm && (
        <div
          aria-labelledby="discard-confirm-label"
          aria-modal="true"
          className="absolute inset-0 z-50 flex items-center justify-center bg-black/40"
          role="dialog"
        >
          <div className="rounded-lg border border-gray-200 bg-white p-6 shadow-xl dark:border-gray-700 dark:bg-gray-900">
            <p className="mb-5 text-sm font-medium text-gray-800 dark:text-gray-100" id="discard-confirm-label">
              {t("image_annotation.discard_confirm")}
            </p>
            <div className="flex justify-end gap-2">
              <button
                className={secondaryButton()}
                onClick={() => setShowDiscardConfirm(false)}
                type="button"
              >
                {t("image_annotation.keep_editing")}
              </button>
              <button
                className="rounded bg-red-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-red-700"
                onClick={() => { setShowDiscardConfirm(false); onClose() }}
                type="button"
              >
                {t("image_annotation.discard")}
              </button>
            </div>
          </div>
        </div>
      )}
      <section aria-label={t("image_annotation.annotate", { name })} aria-modal="true" className="flex min-h-0 flex-1 flex-col gap-3" role="dialog">
        <div className="flex flex-wrap items-center justify-between gap-2 rounded border border-gray-200 bg-white px-3 py-2 shadow dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-center gap-1" role="toolbar" aria-label={t("image_annotation.toolbar")}>
            {TOOLS.map((item) => (
              <button
                aria-pressed={tool === item.id}
                className={`rounded px-2.5 py-1 text-sm font-medium ${tool === item.id ? "bg-blue-600 text-white" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`}
                key={item.id}
                onClick={() => setTool(item.id)}
                type="button"
              >
                {t(`image_annotation.tool_${item.id}`)}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1" role="radiogroup" aria-label={t("image_annotation.colors")}>
            {COLORS.map((item) => (
              <button
                aria-label={t(`image_annotation.color_${item.key}`)}
                aria-checked={color === item.value}
                className={`h-7 w-7 rounded-full border ${color === item.value ? "border-blue-600 ring-2 ring-blue-500 ring-offset-1 dark:ring-offset-gray-900" : "border-gray-300 dark:border-gray-600"}`}
                key={item.value}
                onClick={() => setColor(item.value)}
                role="radio"
                style={{ backgroundColor: item.value }}
                type="button"
              />
            ))}
          </div>
          <div className="flex items-center gap-2">
            <button className={secondaryButton()} disabled={undoCount === 0} onClick={undo} type="button">{t("image_annotation.undo")}</button>
            <button className={secondaryButton()} disabled={redoCount === 0} onClick={redo} type="button">{t("image_annotation.redo")}</button>
            <button className={secondaryButton()} onClick={requestClose} type="button">{t("image_annotation.cancel")}</button>
            <button className="rounded bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:bg-blue-300" disabled={!imageSize} onClick={finishAnnotation} type="button">{t("image_annotation.done")}</button>
            <button aria-label={t("image_annotation.close")} className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-800 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" onClick={requestClose} type="button">
              <CloseIcon className="h-4 w-4" />
            </button>
          </div>
        </div>
        <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden">
          <div className="flex items-center gap-2">
            <div className="relative max-h-[calc(100dvh-6rem)] max-w-[calc(100vw-4rem)]" style={canvasStyle}>
              <div
                className="relative"
                style={{ transform: wrapperTransform, transformOrigin: "0 0" }}
              >
                <canvas aria-hidden="true" className="block max-h-[calc(100dvh-6rem)] max-w-full rounded bg-white object-contain shadow-lg" ref={imageCanvasRef} />
                <canvas
                  aria-label={t("image_annotation.canvas")}
                  className="absolute inset-0 h-full w-full touch-none rounded"
                  onPointerDown={handlePointerDown}
                  onPointerMove={handlePointerMove}
                  onPointerUp={handlePointerUp}
                  onPointerCancel={handlePointerUp}
                  ref={overlayCanvasRef}
                  style={overlayCursor ? { cursor: overlayCursor } : undefined}
                />
                {textPlacement ? (
                  <input
                    aria-label={t("image_annotation.text_input")}
                    autoFocus
                    className="absolute min-w-32 -translate-y-1/2 rounded border border-blue-500 bg-white px-2 py-1 text-xl font-bold shadow focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-900"
                    onChange={(event) => setTextPlacement((current) => current ? { ...current, value: event.target.value } : current)}
                    onKeyDown={handleTextKeyDown}
                    placeholder={t("image_annotation.text_placeholder")}
                    style={inputStyle}
                    value={textPlacement.value}
                  />
                ) : null}
              </div>
            </div>

            {/* Zoom bar */}
            <div className="flex flex-col items-center gap-1 self-stretch justify-center py-2">
              <button
                aria-label={t("image_annotation.zoom_in")}
                className={secondaryButton() + " px-2 py-1 text-base font-bold"}
                disabled={zoom >= ZOOM_MAX}
                onClick={() => changeZoom(ZOOM_STEP)}
                type="button"
              >
                +
              </button>
              <input
                aria-label={t("image_annotation.zoom_label")}
                className="h-24"
                max={ZOOM_MAX}
                min={ZOOM_MIN}
                onChange={(e) => setZoom(clampZoom(Number(e.target.value)))}
                step={0.05}
                style={{ writingMode: "vertical-lr", direction: "rtl", appearance: "slider-vertical" } as unknown as React.CSSProperties}
                type="range"
                value={zoom}
              />
              <button
                aria-label={t("image_annotation.zoom_out")}
                className={secondaryButton() + " px-2 py-1 text-base font-bold"}
                disabled={zoom <= ZOOM_MIN}
                onClick={() => changeZoom(-ZOOM_STEP)}
                type="button"
              >
                −
              </button>
              <span className="text-xs text-gray-500 dark:text-gray-400" aria-live="polite">
                {Math.round(zoom * 100)}%
              </span>
            </div>
          </div>
        </div>
      </section>
    </div>
  )
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:border-gray-200 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
}
