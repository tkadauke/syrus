import type { ToolCardExample } from "@app/pluginToolCards"
import { makeElementCard } from "../whiteboardToolCard"

export const examples: ToolCardExample[] = [
  {
    id: "named_frame",
    label: "Named frame",
    input: {
      type: "magicframe",
      name: "Release plan",
      x: 24,
      y: 48,
      width: 640,
      height: 360
    },
    parsedResult: { id: "frame-demo", version: 5 },
    sourceType: "generic"
  },
  {
    id: "wrapped_result",
    label: "Wrapped result envelope",
    input: { type: "frame", name: "Architecture", x: 0, y: 0, width: 480, height: 320 },
    parsedResult: { result: { id: "frame-wrapped", version: 2 } },
    sourceType: "generic"
  },
  {
    id: "invalid_bounds",
    label: "Invalid frame bounds",
    input: { type: "frame", name: "Broken frame", x: 10, y: 20, width: -1, height: 100 },
    parsedResult: { message: "width must be greater than zero", retryable: false },
    resultError: true,
    sourceType: "generic"
  },
  {
    id: "pending",
    label: "Pending result",
    input: { type: "frame", name: "Pending frame", x: 10, y: 20, width: 300, height: 200 },
    resultBody: "",
    sourceType: "generic"
  }
]

export default makeElementCard("draw_frame", "tool_action_drew_frame")
