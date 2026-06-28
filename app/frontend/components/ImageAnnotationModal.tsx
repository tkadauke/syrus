import { useCallback, useEffect, useRef, useState, type KeyboardEvent, type PointerEvent as ReactPointerEvent } from "react"
import { CloseIcon } from "./CloseIcon"

type Tool = "rectangle" | "ellipse" | "line" | "arrow" | "freehand" | "text"

type Point = {
  x: number
  y: number
}

type TextPlacement = Point & {
  value: string
}

const TOOLS: Array<{ id: Tool; label: string }> = [
  { id: "rectangle", label: "Rectangle" },
  { id: "ellipse", label: "Ellipse" },
  { id: "line", label: "Line" },
  { id: "arrow", label: "Arrow" },
  { id: "freehand", label: "Freehand" },
  { id: "text", label: "Text" }
]

const COLORS = [
  { label: "Red", value: "#ef4444" },
  { label: "Blue", value: "#3b82f6" },
  { label: "Yellow", value: "#eab308" },
  { label: "Green", value: "#22c55e" },
  { label: "White", value: "#ffffff" },
  { label: "Black", value: "#000000" }
]

const STROKE_WIDTH = 3
const TEXT_FONT = "bold 20px sans-serif"
const MAX_UNDO_STEPS = 50

export function ImageAnnotationModal({ dataUrl, name, onDone, onClose }: { dataUrl: string; name: string; onDone: (annotatedDataUrl: string) => void; onClose: () => void }) {
  const imageCanvasRef = useRef<HTMLCanvasElement | null>(null)
  const overlayCanvasRef = useRef<HTMLCanvasElement | null>(null)
  const undoStackRef = useRef<ImageData[]>([])
  const drawingRef = useRef<{ start: Point; last: Point; snapshot: ImageData | null; pointerId: number; freehand: boolean } | null>(null)
  const [tool, setTool] = useState<Tool>("rectangle")
  const [color, setColor] = useState(COLORS[0].value)
  const [imageSize, setImageSize] = useState<{ width: number; height: number } | null>(null)
  const [undoCount, setUndoCount] = useState(0)
  const [textPlacement, setTextPlacement] = useState<TextPlacement | null>(null)

  const syncUndoCount = useCallback(() => setUndoCount(undoStackRef.current.length), [])

  const pushSnapshot = useCallback(() => {
    const canvas = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!canvas || !context) return

    const snapshot = context.getImageData(0, 0, canvas.width, canvas.height)
    const initialSnapshot = undoStackRef.current[0]
    if (initialSnapshot) {
      const recentSnapshots = [...undoStackRef.current.slice(1), snapshot].slice(-(MAX_UNDO_STEPS - 1))
      undoStackRef.current = [initialSnapshot, ...recentSnapshots]
    } else {
      undoStackRef.current = [snapshot]
    }
    syncUndoCount()
  }, [syncUndoCount])

  const undo = useCallback(() => {
    const canvas = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!canvas || !context || undoStackRef.current.length <= 1) return

    undoStackRef.current = undoStackRef.current.slice(0, -1)
    const snapshot = undoStackRef.current[undoStackRef.current.length - 1]
    context.putImageData(snapshot, 0, 0)
    syncUndoCount()
  }, [syncUndoCount])

  useEffect(() => {
    let cancelled = false
    const image = new Image()
    image.onload = () => {
      if (cancelled) return

      const width = image.naturalWidth || image.width
      const height = image.naturalHeight || image.height
      const imageCanvas = imageCanvasRef.current
      const overlayCanvas = overlayCanvasRef.current
      const imageContext = imageCanvas?.getContext("2d")
      const overlayContext = overlayCanvas?.getContext("2d")
      if (!width || !height || !imageCanvas || !overlayCanvas || !imageContext || !overlayContext) return

      imageCanvas.width = width
      imageCanvas.height = height
      overlayCanvas.width = width
      overlayCanvas.height = height
      imageContext.clearRect(0, 0, width, height)
      imageContext.drawImage(image, 0, 0, width, height)
      overlayContext.clearRect(0, 0, width, height)
      undoStackRef.current = [overlayContext.getImageData(0, 0, width, height)]
      setImageSize({ width, height })
      syncUndoCount()
    }
    image.src = dataUrl

    return () => {
      cancelled = true
    }
  }, [dataUrl, syncUndoCount])

  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose()
        return
      }

      if (event.key.toLowerCase() === "z" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        undo()
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [onClose, undo])

  function canvasPoint(event: ReactPointerEvent<HTMLCanvasElement>): Point {
    const canvas = event.currentTarget
    const rect = canvas.getBoundingClientRect()
    const scaleX = rect.width ? canvas.width / rect.width : 1
    const scaleY = rect.height ? canvas.height / rect.height : 1
    return {
      x: Math.max(0, Math.min(canvas.width, (event.clientX - rect.left) * scaleX)),
      y: Math.max(0, Math.min(canvas.height, (event.clientY - rect.top) * scaleY))
    }
  }

  function configureStroke(context: CanvasRenderingContext2D) {
    context.strokeStyle = color
    context.fillStyle = color
    context.lineWidth = STROKE_WIDTH
    context.lineCap = "round"
    context.lineJoin = "round"
    context.font = TEXT_FONT
  }

  function drawShape(context: CanvasRenderingContext2D, start: Point, end: Point, selectedTool = tool) {
    configureStroke(context)
    context.beginPath()

    if (selectedTool === "rectangle") {
      context.rect(start.x, start.y, end.x - start.x, end.y - start.y)
      context.stroke()
      return
    }

    if (selectedTool === "ellipse") {
      const centerX = (start.x + end.x) / 2
      const centerY = (start.y + end.y) / 2
      context.ellipse(centerX, centerY, Math.abs(end.x - start.x) / 2, Math.abs(end.y - start.y) / 2, 0, 0, Math.PI * 2)
      context.stroke()
      return
    }

    context.moveTo(start.x, start.y)
    context.lineTo(end.x, end.y)
    context.stroke()

    if (selectedTool === "arrow") drawArrowHead(context, start, end)
  }

  function drawArrowHead(context: CanvasRenderingContext2D, start: Point, end: Point) {
    const angle = Math.atan2(end.y - start.y, end.x - start.x)
    const headLength = 16
    context.beginPath()
    context.moveTo(end.x, end.y)
    context.lineTo(end.x - headLength * Math.cos(angle - Math.PI / 6), end.y - headLength * Math.sin(angle - Math.PI / 6))
    context.moveTo(end.x, end.y)
    context.lineTo(end.x - headLength * Math.cos(angle + Math.PI / 6), end.y - headLength * Math.sin(angle + Math.PI / 6))
    context.stroke()
  }

  function handlePointerDown(event: ReactPointerEvent<HTMLCanvasElement>) {
    if (!imageSize) return
    const canvas = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!canvas || !context) return

    const point = canvasPoint(event)
    if (tool === "text") {
      setTextPlacement({ ...point, value: "" })
      return
    }

    event.currentTarget.setPointerCapture?.(event.pointerId)
    const snapshot = context.getImageData(0, 0, canvas.width, canvas.height)
    drawingRef.current = { start: point, last: point, snapshot, pointerId: event.pointerId, freehand: tool === "freehand" }

    if (tool === "freehand") {
      configureStroke(context)
      context.beginPath()
      context.moveTo(point.x, point.y)
    }
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLCanvasElement>) {
    const drawing = drawingRef.current
    const canvas = overlayCanvasRef.current
    const context = canvas?.getContext("2d")
    if (!drawing || !canvas || !context) return

    const point = canvasPoint(event)
    if (drawing.freehand) {
      configureStroke(context)
      context.lineTo(point.x, point.y)
      context.stroke()
      drawing.last = point
      return
    }

    if (drawing.snapshot) context.putImageData(drawing.snapshot, 0, 0)
    drawShape(context, drawing.start, point)
    drawing.last = point
  }

  function handlePointerUp(event: ReactPointerEvent<HTMLCanvasElement>) {
    const drawing = drawingRef.current
    if (!drawing) return

    if (event.currentTarget.hasPointerCapture?.(drawing.pointerId)) {
      event.currentTarget.releasePointerCapture(drawing.pointerId)
    }

    if (drawing.start.x !== drawing.last.x || drawing.start.y !== drawing.last.y) {
      pushSnapshot()
    } else if (drawing.snapshot) {
      overlayCanvasRef.current?.getContext("2d")?.putImageData(drawing.snapshot, 0, 0)
    }

    drawingRef.current = null
  }

  function commitText() {
    if (!textPlacement) return
    const value = textPlacement.value.trim()
    if (!value) {
      setTextPlacement(null)
      return
    }

    const context = overlayCanvasRef.current?.getContext("2d")
    if (!context) return
    configureStroke(context)
    context.fillText(value, textPlacement.x, textPlacement.y)
    setTextPlacement(null)
    pushSnapshot()
  }

  function handleTextKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key === "Enter") {
      event.preventDefault()
      commitText()
    }

    if (event.key === "Escape") {
      event.preventDefault()
      setTextPlacement(null)
    }
  }

  function finishAnnotation() {
    const imageCanvas = imageCanvasRef.current
    const overlayCanvas = overlayCanvasRef.current
    const context = imageCanvas?.getContext("2d")
    if (!imageCanvas || !overlayCanvas || !context) return

    context.drawImage(overlayCanvas, 0, 0)
    onDone(imageCanvas.toDataURL("image/png"))
  }

  const canvasStyle = imageSize ? { aspectRatio: `${imageSize.width} / ${imageSize.height}` } : undefined
  const inputStyle = textPlacement && imageSize ? {
    left: `${(textPlacement.x / imageSize.width) * 100}%`,
    top: `${(textPlacement.y / imageSize.height) * 100}%`,
    color
  } : undefined

  return (
    <div className="fixed inset-0 z-40 flex flex-col bg-gray-950/80 p-3 text-gray-900 dark:text-gray-100" role="presentation">
      <section aria-label={`Annotate ${name}`} aria-modal="true" className="flex min-h-0 flex-1 flex-col gap-3" role="dialog">
        <div className="flex flex-wrap items-center justify-between gap-2 rounded border border-gray-200 bg-white px-3 py-2 shadow dark:border-gray-700 dark:bg-gray-900">
          <div className="flex flex-wrap items-center gap-1" role="toolbar" aria-label="Annotation tools">
            {TOOLS.map((item) => (
              <button
                aria-pressed={tool === item.id}
                className={`rounded px-2.5 py-1 text-sm font-medium ${tool === item.id ? "bg-blue-600 text-white" : "text-gray-700 hover:bg-gray-100 dark:text-gray-200 dark:hover:bg-gray-800"}`}
                key={item.id}
                onClick={() => setTool(item.id)}
                type="button"
              >
                {item.label}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1" role="radiogroup" aria-label="Annotation color">
            {COLORS.map((item) => (
              <button
                aria-label={item.label}
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
            <button className={secondaryButton()} disabled={undoCount <= 1} onClick={undo} type="button">Undo</button>
            <button className={secondaryButton()} onClick={onClose} type="button">Cancel</button>
            <button className="rounded bg-blue-600 px-3 py-1.5 text-sm font-semibold text-white hover:bg-blue-700 disabled:bg-blue-300" disabled={!imageSize} onClick={finishAnnotation} type="button">Done</button>
            <button aria-label="Close annotation editor" className="rounded p-1.5 text-gray-500 hover:bg-gray-100 hover:text-gray-800 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100" onClick={onClose} type="button">
              <CloseIcon className="h-4 w-4" />
            </button>
          </div>
        </div>
        <div className="flex min-h-0 flex-1 items-center justify-center overflow-auto">
          <div className="relative max-h-[calc(100dvh-6rem)] max-w-[calc(100vw-1.5rem)]" style={canvasStyle}>
            <canvas aria-hidden="true" className="block max-h-[calc(100dvh-6rem)] max-w-full rounded bg-white object-contain shadow-lg" ref={imageCanvasRef} />
            <canvas
              aria-label="Annotation canvas"
              className="absolute inset-0 h-full w-full touch-none rounded"
              onPointerDown={handlePointerDown}
              onPointerMove={handlePointerMove}
              onPointerUp={handlePointerUp}
              onPointerCancel={handlePointerUp}
              ref={overlayCanvasRef}
            />
            {textPlacement ? (
              <input
                aria-label="Annotation text"
                autoFocus
                className="absolute min-w-32 -translate-y-1/2 rounded border border-blue-500 bg-white px-2 py-1 text-xl font-bold shadow focus:outline-none focus:ring-2 focus:ring-blue-500 dark:bg-gray-900"
                onBlur={commitText}
                onChange={(event) => setTextPlacement((current) => current ? { ...current, value: event.target.value } : current)}
                onKeyDown={handleTextKeyDown}
                style={inputStyle}
                value={textPlacement.value}
              />
            ) : null}
          </div>
        </div>
      </section>
    </div>
  )
}

function secondaryButton() {
  return "rounded border border-gray-300 bg-white px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:border-gray-200 disabled:text-gray-300 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800 dark:disabled:text-gray-600"
}
