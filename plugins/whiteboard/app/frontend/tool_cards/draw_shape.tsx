import { makeElementCard } from "../whiteboardToolCard"
import type { ToolCardExample } from "@app/pluginToolCards"

export const examples: ToolCardExample[] = [
  {
    id: "colored_diamond",
    label: "Colored diamond",
    input: { type: "diamond", x: 40, y: 60, width: 240, height: 120, color: "#f59e0b" },
    parsedResult: { id: "shape-demo", version: 2 }
  },
  { id: "pending", label: "Pending result", input: { type: "rectangle", x: 10, y: 10, width: 100, height: 80 }, resultBody: "" },
  {
    id: "element_limit",
    label: "Element limit exceeded",
    input: { type: "ellipse", x: 10, y: 10, width: 100, height: 80 },
    parsedResult: { error_class: "Whiteboard::Canvas::ElementLimitExceeded", message: "Canvas element limit exceeded" },
    resultError: true
  }
]

export default makeElementCard("draw_shape", "tool_action_drew_shape")
