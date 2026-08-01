import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { type GraphEdge, type GraphNode, TopoDepGraph, computeNodeLayers } from "./TopoDepGraph"

const mockNavigate = vi.fn()
vi.mock("react-router-dom", async (importOriginal) => {
  const mod = await importOriginal<typeof import("react-router-dom")>()
  return { ...mod, useNavigate: () => mockNavigate }
})

function node(id: string, overrides: Partial<GraphNode> = {}): GraphNode {
  return {
    id,
    kind: "epic",
    label: `${id} Test label`,
    state: "open",
    epic_id: 1,
    url: `/epics/${id}`,
    is_focal: false,
    ...overrides,
  }
}

function edge(from_id: string, to_id: string): GraphEdge {
  return { from_id, to_id }
}

function renderGraph(nodes: GraphNode[], edges: GraphEdge[]) {
  render(
    <MemoryRouter>
      <TopoDepGraph edges={edges} nodes={nodes} />
    </MemoryRouter>
  )
}

// --- Layer assignment logic ---

describe("computeNodeLayers", () => {
  it("assigns layer 0 to all nodes when there are no edges", () => {
    const nodes = [node("a"), node("b"), node("c")]
    const layers = computeNodeLayers(nodes, [])
    expect(layers.get("a")).toBe(0)
    expect(layers.get("b")).toBe(0)
    expect(layers.get("c")).toBe(0)
  })

  it("assigns layer 1 to a direct successor", () => {
    const nodes = [node("a"), node("b")]
    const layers = computeNodeLayers(nodes, [edge("a", "b")])
    expect(layers.get("a")).toBe(0)
    expect(layers.get("b")).toBe(1)
  })

  it("assigns increasing layers along a chain", () => {
    const nodes = [node("a"), node("b"), node("c")]
    const layers = computeNodeLayers(nodes, [edge("a", "b"), edge("b", "c")])
    expect(layers.get("a")).toBe(0)
    expect(layers.get("b")).toBe(1)
    expect(layers.get("c")).toBe(2)
  })

  it("assigns the maximum predecessor layer plus one for a diamond shape", () => {
    // a → b
    // a → c
    // b → d   (d should land at layer 2, not 1)
    // c → d
    const nodes = [node("a"), node("b"), node("c"), node("d")]
    const edges = [edge("a", "b"), edge("a", "c"), edge("b", "d"), edge("c", "d")]
    const layers = computeNodeLayers(nodes, edges)
    expect(layers.get("a")).toBe(0)
    expect(layers.get("b")).toBe(1)
    expect(layers.get("c")).toBe(1)
    expect(layers.get("d")).toBe(2)
  })

  it("handles nodes not referenced by any edge", () => {
    const nodes = [node("a"), node("b"), node("isolated")]
    const layers = computeNodeLayers(nodes, [edge("a", "b")])
    expect(layers.get("isolated")).toBe(0)
  })

  it("ignores edges that reference unknown node IDs", () => {
    const nodes = [node("a")]
    const layers = computeNodeLayers(nodes, [edge("a", "ghost")])
    expect(layers.get("a")).toBe(0)
  })

  it("returns an empty map for an empty node list", () => {
    const layers = computeNodeLayers([], [])
    expect(layers.size).toBe(0)
  })

  it("assigns deeper layers to a long chain", () => {
    const nodes = [node("a"), node("b"), node("c"), node("d"), node("e")]
    const edges = [edge("a", "b"), edge("b", "c"), edge("c", "d"), edge("d", "e")]
    const layers = computeNodeLayers(nodes, edges)
    expect(layers.get("e")).toBe(4)
  })
})

// --- Render ---

describe("TopoDepGraph", () => {
  beforeEach(() => {
    mockNavigate.mockReset()
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("renders nothing when there are no nodes", () => {
    const { container } = render(
      <MemoryRouter>
        <TopoDepGraph edges={[]} nodes={[]} />
      </MemoryRouter>
    )
    expect(container.firstChild).toBeNull()
  })

  it("renders a button for each node showing its label", () => {
    renderGraph(
      [
        node("epic_1", { label: "EPIC-1 My Epic" }),
        node("epic_2", { label: "EPIC-2 Other Epic" }),
      ],
      []
    )
    expect(screen.getByText("My Epic")).toBeInTheDocument()
    expect(screen.getByText("Other Epic")).toBeInTheDocument()
  })

  it("renders the slug portion of the label in monospace", () => {
    renderGraph([node("n", { label: "EPIC-7 Big feature" })], [])
    expect(screen.getByText("EPIC-7")).toBeInTheDocument()
    expect(screen.getByText("Big feature")).toBeInTheDocument()
  })

  it("renders the state pill for each node", () => {
    renderGraph([node("n", { state: "open" })], [])
    expect(screen.getByText("open")).toBeInTheDocument()
  })

  it("applies focal ring styling to the focal node", () => {
    renderGraph([node("f", { is_focal: true })], [])
    expect(screen.getByTestId("epic-compact-card").className).toContain("ring-2")
  })

  it("does not apply ring styling to non-focal nodes", () => {
    renderGraph([node("n", { is_focal: false })], [])
    expect(screen.getByTestId("epic-compact-card").className).not.toContain("ring-2")
  })

  it("applies a gray left accent to epicless job nodes", () => {
    renderGraph([node("j", { kind: "job", epic_id: null })], [])
    expect(screen.getByTestId("job-compact-card").className).toContain("border-l-4")
  })

  it("does not apply a left accent to job nodes that belong to an epic", () => {
    renderGraph([node("j", { kind: "job", epic_id: 5 })], [])
    expect(screen.getByTestId("job-compact-card").className).not.toContain("border-l-4")
  })

  it("does not apply a left accent to epic nodes", () => {
    renderGraph([node("e", { kind: "epic", epic_id: null })], [])
    expect(screen.getByTestId("epic-compact-card").className).not.toContain("border-l-4")
  })

  it("navigates to the node url when clicked", () => {
    renderGraph([node("n", { url: "/epics/EPIC-7" })], [])
    fireEvent.click(screen.getByTestId("epic-compact-card"))
    expect(mockNavigate).toHaveBeenCalledWith("/epics/EPIC-7")
  })

  it("navigates to job url for job nodes", () => {
    renderGraph([node("j", { kind: "job", url: "/jobs/JOB-42" })], [])
    fireEvent.click(screen.getByTestId("job-compact-card"))
    expect(mockNavigate).toHaveBeenCalledWith("/jobs/JOB-42")
  })

  it("renders all nodes as compact cards", () => {
    renderGraph([node("a"), node("b"), node("c")], [])
    expect(screen.getAllByTestId("epic-compact-card")).toHaveLength(3)
  })

  it("renders graph slugs as copyable controls without navigating the card", () => {
    renderGraph([node("epic_7", { label: "EPIC-7 Big feature", url: "/epics/7" })], [])

    fireEvent.click(screen.getByRole("button", { name: "Copy EPIC-7 to clipboard" }))

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("EPIC-7")
    expect(mockNavigate).not.toHaveBeenCalled()
  })

  it("removes old arrows immediately when the graph changes", () => {
    const { container, rerender } = render(
      <MemoryRouter>
        <TopoDepGraph edges={[edge("a", "b")]} nodes={[node("a"), node("b")]} />
      </MemoryRouter>
    )

    expect(container.querySelectorAll("path[marker-end]")).toHaveLength(1)

    rerender(
      <MemoryRouter>
        <TopoDepGraph edges={[]} nodes={[node("a")]} />
      </MemoryRouter>
    )

    expect(container.querySelectorAll("path[marker-end]")).toHaveLength(0)
  })

  it("places nodes with edges in separate columns", () => {
    renderGraph([node("a"), node("b")], [edge("a", "b")])
    // Both nodes rendered in separate layer-columns
    expect(screen.getAllByTestId("epic-compact-card")).toHaveLength(2)
  })

  it("accepts a className prop applied to the container", () => {
    const { container } = render(
      <MemoryRouter>
        <TopoDepGraph className="my-custom" edges={[]} nodes={[node("n")]} />
      </MemoryRouter>
    )
    expect(container.firstChild).toHaveClass("my-custom")
  })

  it("sizes the graph to its content so overflow parents can scroll it", () => {
    const { container } = render(
      <MemoryRouter>
        <TopoDepGraph edges={[edge("a", "b")]} nodes={[node("a"), node("b")]} />
      </MemoryRouter>
    )

    expect(container.firstChild).toHaveClass("min-w-full")
    expect(container.firstChild).toHaveClass("w-max")
  })

  it("renders a label with no title portion without an extra paragraph", () => {
    renderGraph([node("n", { label: "SOLO" })], [])
    expect(screen.getByText("SOLO")).toBeInTheDocument()
    // No trailing paragraph for the empty title
    expect(screen.queryByRole("paragraph")).not.toBeInTheDocument()
  })
})
