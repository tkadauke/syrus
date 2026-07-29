import { useLayoutEffect, useRef, useState } from "react"
import { useNavigate } from "react-router-dom"
import { StatusPill } from "./StatusPill"

export type GraphNode = {
  id: string
  kind: "epic" | "job"
  label: string
  state: string
  epic_id: number | null
  url: string
  is_focal: boolean
}

export type GraphEdge = {
  from_id: string
  to_id: string
}

// Exported for testing. Assigns each node its leftmost column (layer 0 = no
// predecessors, layer N = max predecessor layer + 1). Iterates until stable;
// safe for acyclic graphs of any shape. Nodes in cycles or orphaned by edges
// that reference unknown IDs default to layer 0.
export function computeNodeLayers(nodes: GraphNode[], edges: GraphEdge[]): Map<string, number> {
  const predecessors = new Map<string, string[]>()
  for (const node of nodes) predecessors.set(node.id, [])
  for (const edge of edges) {
    if (predecessors.has(edge.to_id)) {
      predecessors.get(edge.to_id)!.push(edge.from_id)
    }
  }

  const layers = new Map<string, number>()
  for (const node of nodes) layers.set(node.id, 0)

  let changed = true
  while (changed) {
    changed = false
    for (const node of nodes) {
      const preds = predecessors.get(node.id) ?? []
      if (preds.length === 0) continue
      const maxPredLayer = Math.max(...preds.map((p) => layers.get(p) ?? 0))
      const next = maxPredLayer + 1
      if (next !== layers.get(node.id)) {
        layers.set(node.id, next)
        changed = true
      }
    }
  }

  return layers
}

type ArrowPath = { key: string; d: string }

export function TopoDepGraph({
  nodes,
  edges,
  className,
}: {
  nodes: GraphNode[]
  edges: GraphEdge[]
  className?: string
}) {
  const navigate = useNavigate()
  const containerRef = useRef<HTMLDivElement>(null)
  const nodeRefs = useRef(new Map<string, Element>())
  const [arrows, setArrows] = useState<ArrowPath[]>([])
  const [svgDims, setSvgDims] = useState({ w: 0, h: 0 })

  const layers = computeNodeLayers(nodes, edges)
  const maxLayer = nodes.length === 0 ? -1 : Math.max(...Array.from(layers.values()))
  const columns: GraphNode[][] = Array.from({ length: maxLayer + 1 }, () => [])
  for (const node of nodes) columns[layers.get(node.id) ?? 0].push(node)

  useLayoutEffect(() => {
    const container = containerRef.current
    if (!container) return

    const cRect = container.getBoundingClientRect()
    const next: ArrowPath[] = []

    for (const edge of edges) {
      const fromEl = nodeRefs.current.get(edge.from_id)
      const toEl = nodeRefs.current.get(edge.to_id)
      if (!fromEl || !toEl) continue

      const fr = fromEl.getBoundingClientRect()
      const tr = toEl.getBoundingClientRect()
      const x1 = fr.right - cRect.left
      const y1 = fr.top - cRect.top + fr.height / 2
      const x2 = tr.left - cRect.left
      const y2 = tr.top - cRect.top + tr.height / 2
      const dx = (x2 - x1) * 0.45

      next.push({
        key: `${edge.from_id}→${edge.to_id}`,
        d: `M ${x1} ${y1} C ${x1 + dx} ${y1} ${x2 - dx} ${y2} ${x2} ${y2}`,
      })
    }

    // Return prev unchanged if computed value is identical — prevents re-render loop.
    setArrows((prev) => (JSON.stringify(prev) === JSON.stringify(next) ? prev : next))
    setSvgDims((prev) => {
      const w = Math.ceil(cRect.width)
      const h = Math.ceil(cRect.height)
      return prev.w === w && prev.h === h ? prev : { w, h }
    })
  })

  if (nodes.length === 0) return null

  return (
    <div className={["relative", className].filter(Boolean).join(" ")} ref={containerRef}>
      <div className="flex items-start gap-16">
        {columns.map((colNodes, colIdx) => (
          <div className="flex flex-col gap-3" key={colIdx}>
            {colNodes.map((node) => {
              const isEpiclessJob = node.kind === "job" && node.epic_id === null
              const spaceIdx = node.label.indexOf(" ")
              const slug = spaceIdx === -1 ? node.label : node.label.slice(0, spaceIdx)
              const title = spaceIdx === -1 ? "" : node.label.slice(spaceIdx + 1)

              return (
                <button
                  className={[
                    "w-48 rounded-lg border bg-white p-3 text-left shadow-sm transition-shadow hover:shadow-md dark:bg-gray-900",
                    node.is_focal
                      ? "border-gray-900 ring-2 ring-gray-900 dark:border-gray-100 dark:ring-gray-100"
                      : "border-gray-200 dark:border-gray-700",
                    isEpiclessJob ? "border-l-4 border-l-gray-400 dark:border-l-gray-600" : "",
                  ]
                    .filter(Boolean)
                    .join(" ")}
                  key={node.id}
                  onClick={() => navigate(node.url)}
                  ref={(el) => {
                    if (el) nodeRefs.current.set(node.id, el)
                    else nodeRefs.current.delete(node.id)
                  }}
                >
                  <div className="mb-1 flex items-center gap-1.5 overflow-hidden">
                    <span className="shrink-0 font-mono text-xs text-gray-500 dark:text-gray-400">
                      {slug}
                    </span>
                    <StatusPill state={node.state} />
                  </div>
                  {title && (
                    <p className="truncate text-xs text-gray-700 dark:text-gray-300">{title}</p>
                  )}
                </button>
              )
            })}
          </div>
        ))}
      </div>

      <svg
        aria-hidden="true"
        className="pointer-events-none absolute inset-0"
        height={svgDims.h}
        width={svgDims.w}
      >
        <defs>
          <marker
            id="topo-arrow"
            markerHeight="6"
            markerUnits="strokeWidth"
            markerWidth="6"
            orient="auto"
            refX="5"
            refY="3"
          >
            <path d="M 0 0 L 6 3 L 0 6 z" fill="#9ca3af" />
          </marker>
        </defs>
        {arrows.map(({ key, d }) => (
          <path
            d={d}
            fill="none"
            key={key}
            markerEnd="url(#topo-arrow)"
            stroke="#9ca3af"
            strokeWidth="1.5"
          />
        ))}
      </svg>
    </div>
  )
}
