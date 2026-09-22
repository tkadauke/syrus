import { useId, useLayoutEffect, useMemo, useRef, useState } from "react"
import { useNavigate } from "react-router-dom"
import { CopyableSlug } from "./CopyableSlug"
import { EpicCompactCard } from "./EpicPreviewCard"
import { JobCompactCard } from "./JobPreviewCard"
import { SlugHoverCard } from "./SlugHoverCard"

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

// --- Crossing-reduction layout ---
//
// computeNodeLayers only assigns each node a column (layer). Within a
// column, cards were previously kept in raw API/input order, which produces
// avoidable diagonal crossings when a later column has a different relative
// order than its predecessors. computeGraphLayout runs a classic Sugiyama-
// style pass on top of the layer assignment: synthesize dummy nodes for
// edges that skip columns (so the sweep can reason about the lanes they
// pass through), then repeatedly reorder each column by the average
// ("barycenter") position of its neighbors in the adjacent, already-settled
// column, alternating sweep direction. Ties are broken deterministically so
// the layout never jitters between renders of the same graph.
const CROSSING_REDUCTION_ITERATIONS = 4
const DUMMY_KEY_PREFIX = "__topo_dummy__"

interface LayoutNode {
  key: string
  node: GraphNode | null
  seed: number
  numericId: number | null
  labelId: string
}

interface GraphLayout {
  columns: GraphNode[][]
  layers: Map<string, number>
  // Keyed by `${from_id}→${to_id}` for edges that skip one or more columns.
  // Each entry is the ordered list of relative row positions (0..1) the
  // edge's dummy lane occupies in each intermediate column, so arrow
  // routing can pass through the lane the crossing-reduction sweep chose
  // instead of cutting straight across unrelated columns.
  waypointFractions: Map<string, number[]>
}

function compareLayoutNodes(a: LayoutNode, b: LayoutNode): number {
  if (a.seed !== b.seed) return a.seed - b.seed
  if (a.numericId !== null && b.numericId !== null && a.numericId !== b.numericId) {
    return a.numericId - b.numericId
  }
  if (a.numericId !== null && b.numericId === null) return -1
  if (a.numericId === null && b.numericId !== null) return 1
  return a.labelId < b.labelId ? -1 : a.labelId > b.labelId ? 1 : 0
}

function positionsOf(column: LayoutNode[]): Map<string, number> {
  const positions = new Map<string, number>()
  column.forEach((layoutNode, index) => positions.set(layoutNode.key, index))
  return positions
}

function pushNeighbor(map: Map<string, string[]>, key: string, neighborKey: string) {
  const existing = map.get(key)
  if (existing) existing.push(neighborKey)
  else map.set(key, [neighborKey])
}

// Reorders `column` by the average position of each node's neighbors in the
// adjacent, already-settled column. Nodes with no such neighbor (e.g. a
// dummy lane that hasn't been linked from this side yet) keep their current
// position instead of being pulled to one edge of the column.
function reorderLayer(
  column: LayoutNode[],
  neighborPositions: Map<string, number>,
  neighborsOf: Map<string, string[]>
): LayoutNode[] {
  const scored = column.map((layoutNode, index) => {
    const neighborKeys = neighborsOf.get(layoutNode.key) ?? []
    const positions = neighborKeys
      .map((key) => neighborPositions.get(key))
      .filter((position): position is number => position !== undefined)
    const barycenter = positions.length > 0 ? positions.reduce((sum, p) => sum + p, 0) / positions.length : index
    return { layoutNode, barycenter }
  })

  scored.sort((a, b) => {
    if (a.barycenter !== b.barycenter) return a.barycenter - b.barycenter
    return compareLayoutNodes(a.layoutNode, b.layoutNode)
  })

  return scored.map((entry) => entry.layoutNode)
}

// Exported for testing. Pure function: same (nodes, edges) always produces
// the same layout, so the layout never jitters between renders.
export function computeGraphLayout(nodes: GraphNode[], edges: GraphEdge[]): GraphLayout {
  if (nodes.length === 0) return { columns: [], layers: new Map(), waypointFractions: new Map() }

  const layers = computeNodeLayers(nodes, edges)
  const maxLayer = Math.max(...Array.from(layers.values()))
  const nodeIndex = new Map(nodes.map((node, index) => [node.id, index]))
  const nodeIds = new Set(nodes.map((node) => node.id))

  const columns: LayoutNode[][] = Array.from({ length: maxLayer + 1 }, () => [])
  for (const node of nodes) {
    columns[layers.get(node.id) ?? 0].push({
      key: node.id,
      node,
      seed: nodeIndex.get(node.id) ?? 0,
      numericId: numericNodeId(node),
      labelId: node.label || node.id,
    })
  }

  const segments: { fromKey: string; toKey: string }[] = []
  const dummyLayerByKey = new Map<string, number>()
  const dummyChains: { edgeKey: string; dummyKeys: string[] }[] = []

  edges.forEach((edge, edgeIndex) => {
    if (!nodeIds.has(edge.from_id) || !nodeIds.has(edge.to_id)) return
    const fromLayer = layers.get(edge.from_id) ?? 0
    const toLayer = layers.get(edge.to_id) ?? 0
    if (toLayer <= fromLayer) return // same-layer or backward (cyclic) edge — not usable for ordering
    if (toLayer === fromLayer + 1) {
      segments.push({ fromKey: edge.from_id, toKey: edge.to_id })
      return
    }

    // Edge skips one or more columns: insert a dummy lane node per
    // intermediate layer so the sweep can route around, not through, other
    // columns' real cards.
    const seed = nodeIndex.get(edge.from_id) ?? 0
    const dummyKeys: string[] = []
    let prevKey = edge.from_id
    for (let layer = fromLayer + 1; layer < toLayer; layer++) {
      const dummyKey = `${DUMMY_KEY_PREFIX}${edgeIndex}:${layer}`
      columns[layer].push({ key: dummyKey, node: null, seed, numericId: null, labelId: dummyKey })
      dummyLayerByKey.set(dummyKey, layer)
      segments.push({ fromKey: prevKey, toKey: dummyKey })
      dummyKeys.push(dummyKey)
      prevKey = dummyKey
    }
    segments.push({ fromKey: prevKey, toKey: edge.to_id })
    dummyChains.push({ edgeKey: `${edge.from_id}→${edge.to_id}`, dummyKeys })
  })

  for (const column of columns) column.sort(compareLayoutNodes)

  const forward = new Map<string, string[]>()
  const backward = new Map<string, string[]>()
  for (const segment of segments) {
    pushNeighbor(forward, segment.fromKey, segment.toKey)
    pushNeighbor(backward, segment.toKey, segment.fromKey)
  }

  for (let iteration = 0; iteration < CROSSING_REDUCTION_ITERATIONS; iteration++) {
    if (iteration % 2 === 0) {
      for (let layer = 1; layer <= maxLayer; layer++) {
        columns[layer] = reorderLayer(columns[layer], positionsOf(columns[layer - 1]), backward)
      }
    } else {
      for (let layer = maxLayer - 1; layer >= 0; layer--) {
        columns[layer] = reorderLayer(columns[layer], positionsOf(columns[layer + 1]), forward)
      }
    }
  }

  const waypointFractions = new Map<string, number[]>()
  for (const chain of dummyChains) {
    const fractions = chain.dummyKeys.map((dummyKey) => {
      const layer = dummyLayerByKey.get(dummyKey) ?? 0
      const column = columns[layer]
      const index = column.findIndex((layoutNode) => layoutNode.key === dummyKey)
      return column.length > 1 ? index / (column.length - 1) : 0.5
    })
    waypointFractions.set(chain.edgeKey, fractions)
  }

  return {
    columns: columns.map((column) =>
      column.filter((layoutNode) => layoutNode.node !== null).map((layoutNode) => layoutNode.node as GraphNode)
    ),
    layers,
    waypointFractions,
  }
}

// Exported for testing. Thin wrapper around computeGraphLayout returning
// only the renderable columns (real GraphNodes, ordered to reduce
// crossings) — the shape TopoDepGraph.tsx renders directly.
export function computeOrderedColumns(nodes: GraphNode[], edges: GraphEdge[]): GraphNode[][] {
  return computeGraphLayout(nodes, edges).columns
}

type ArrowPath = { key: string; d: string }
type ArrowLayer = { graphKey: string; paths: ArrowPath[] }

function graphRenderKey(nodes: GraphNode[], edges: GraphEdge[]): string {
  return JSON.stringify({
    nodes: nodes.map((node) => node.id),
    edges: edges.map((edge) => [edge.from_id, edge.to_id]),
  })
}

// Connects waypoints (endpoints plus any intermediate dummy-lane points) with
// a continuous piecewise cubic curve, matching the single-segment curve's
// horizontal-control-point style so multi-column edges read as one smooth
// monotone line rather than several visibly joined segments.
function smoothPathThrough(points: { x: number; y: number }[]): string {
  let d = `M ${points[0].x} ${points[0].y}`
  for (let i = 1; i < points.length; i++) {
    const p = points[i - 1]
    const q = points[i]
    const dx = (q.x - p.x) * 0.45
    d += ` C ${p.x + dx} ${p.y} ${q.x - dx} ${q.y} ${q.x} ${q.y}`
  }
  return d
}

function numericNodeId(node: GraphNode): number | null {
  const idMatch = node.id.match(/_(\d+)$/)
  if (idMatch) return Number.parseInt(idMatch[1], 10)

  const slugMatch = node.label.match(/\b(?:EPIC|JOB)-(\d+)\b/)
  return slugMatch ? Number.parseInt(slugMatch[1], 10) : null
}

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
  const markerId = `topo-arrow-${useId().replace(/:/g, "")}`
  const containerRef = useRef<HTMLDivElement>(null)
  const nodeRefs = useRef(new Map<string, Element>())
  const columnRefs = useRef(new Map<number, Element>())
  const [arrowLayer, setArrowLayer] = useState<ArrowLayer>({ graphKey: "", paths: [] })
  const [svgDims, setSvgDims] = useState({ w: 0, h: 0 })

  const graphKey = useMemo(() => graphRenderKey(nodes, edges), [nodes, edges])
  const layout = useMemo(() => computeGraphLayout(nodes, edges), [nodes, edges])
  const { columns, layers, waypointFractions } = layout

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

      const fromLayer = layers.get(edge.from_id) ?? 0
      const toLayer = layers.get(edge.to_id) ?? 0
      const span = toLayer - fromLayer
      const edgeKey = `${edge.from_id}→${edge.to_id}`

      if (span > 1) {
        const fractions = waypointFractions.get(edgeKey) ?? []
        const points = [{ x: x1, y: y1 }]
        for (let i = 0; i < span - 1; i++) {
          const layer = fromLayer + 1 + i
          const colEl = columnRefs.current.get(layer)
          const fallback = { x: x1 + (x2 - x1) * ((i + 1) / span), y: y1 + (y2 - y1) * ((i + 1) / span) }
          if (colEl) {
            const cr = colEl.getBoundingClientRect()
            const fraction = fractions[i] ?? (i + 1) / span
            points.push(
              cr.height > 0
                ? { x: cr.left - cRect.left + cr.width / 2, y: cr.top - cRect.top + cr.height * fraction }
                : fallback
            )
          } else {
            points.push(fallback)
          }
        }
        points.push({ x: x2, y: y2 })
        next.push({ key: edgeKey, d: smoothPathThrough(points) })
      } else {
        const dx = (x2 - x1) * 0.45
        next.push({
          key: edgeKey,
          d: `M ${x1} ${y1} C ${x1 + dx} ${y1} ${x2 - dx} ${y2} ${x2} ${y2}`,
        })
      }
    }

    // Return prev unchanged if computed value is identical — prevents re-render loop.
    setArrowLayer((prev) =>
      prev.graphKey === graphKey && JSON.stringify(prev.paths) === JSON.stringify(next)
        ? prev
        : { graphKey, paths: next }
    )
    setSvgDims((prev) => {
      const w = Math.ceil(cRect.width)
      const h = Math.ceil(cRect.height)
      return prev.w === w && prev.h === h ? prev : { w, h }
    })
  }, [edges, graphKey, layers, waypointFractions])

  if (nodes.length === 0) return null

  const arrows = arrowLayer.graphKey === graphKey ? arrowLayer.paths : []

  return (
    <div className={["relative min-w-full w-max", className].filter(Boolean).join(" ")} ref={containerRef}>
      <div className="flex items-start gap-16">
        {columns.map((colNodes, colIdx) => (
          <div
            className="flex flex-col gap-3"
            key={colIdx}
            ref={(el) => {
              if (el) columnRefs.current.set(colIdx, el)
              else columnRefs.current.delete(colIdx)
            }}
          >
            {colNodes.map((node) =>
              node.kind === "epic" ? (
                <EpicCompactCard
                  isFocal={node.is_focal}
                  key={node.id}
                  label={node.label}
                  onClick={() => navigate(node.url)}
                  renderSlug={(slug) => <GraphSlug id={numericNodeId(node)} kind="epic" slug={slug} />}
                  ref={(el) => {
                    if (el) nodeRefs.current.set(node.id, el)
                    else nodeRefs.current.delete(node.id)
                  }}
                  state={node.state}
                />
              ) : (
                <JobCompactCard
                  epicId={node.epic_id}
                  isFocal={node.is_focal}
                  key={node.id}
                  label={node.label}
                  onClick={() => navigate(node.url)}
                  renderSlug={(slug) => <GraphSlug id={numericNodeId(node)} kind="job" slug={slug} />}
                  ref={(el) => {
                    if (el) nodeRefs.current.set(node.id, el)
                    else nodeRefs.current.delete(node.id)
                  }}
                  state={node.state}
                />
              )
            )}
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
            id={markerId}
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
            markerEnd={`url(#${markerId})`}
            stroke="#9ca3af"
            strokeWidth="1.5"
          />
        ))}
      </svg>
    </div>
  )
}

function GraphSlug({ id, kind, slug }: { id: number | null; kind: "epic" | "job"; slug: string }) {
  const content = <CopyableSlug className="shrink-0 text-xs" slug={slug} />

  return (
    <span
      className="shrink-0"
      onClick={(event) => event.stopPropagation()}
      onKeyDown={(event) => event.stopPropagation()}
    >
      {id ? (
        <SlugHoverCard id={id} kind={kind}>
          {content}
        </SlugHoverCard>
      ) : content}
    </span>
  )
}
