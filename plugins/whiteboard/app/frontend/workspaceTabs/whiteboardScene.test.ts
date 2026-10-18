import { describe, expect, it } from "vitest"
import { asExcalidrawElements, cloneWhiteboardScene } from "@app/routes/chat/whiteboardScene"

describe("whiteboard arrow labels", () => {
  const arrow = {
    id: "arrow-1",
    type: "arrow",
    x: 100,
    y: 50,
    width: 200,
    height: 0,
    points: [
      [0, 0],
      [200, 0]
    ],
    startBinding: { elementId: "box-1", focus: 0, gap: 1 },
    endBinding: { elementId: "box-2", focus: 0, gap: 1 },
    boundElements: [{ id: "label-1", type: "text" }]
  }
  const label = {
    id: "label-1",
    type: "text",
    text: "flows",
    originalText: "flows",
    containerId: "arrow-1",
    x: 270,
    y: 38,
    width: 60,
    height: 25
  }

  it("passes a bound arrow and its visible label to Excalidraw together", () => {
    const rendered = asExcalidrawElements([arrow, label]) as unknown as Array<Record<string, unknown>>

    expect(rendered).toEqual([arrow, label])
    expect(rendered[0].boundElements).toEqual([{ id: "label-1", type: "text" }])
    expect(rendered[1]).toMatchObject({ text: "flows", containerId: "arrow-1" })
  })

  it("preserves both sides of the binding through a scene round trip", () => {
    const scene = cloneWhiteboardScene({ elements: [arrow, label], appState: {}, files: {} })

    expect(scene.elements).toEqual([arrow, label])
  })
})
