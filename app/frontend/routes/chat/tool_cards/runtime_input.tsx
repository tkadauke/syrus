import type { ToolCardExample } from "@app/pluginToolCards"
import { runtimeToolCardRenderer } from "../runtimeToolCard"

export default runtimeToolCardRenderer("runtime_input")

export const examples: ToolCardExample[] = [
  {
    id: "redacted_typed_input",
    label: "Typed input is redacted",
    description: "Typed text stays masked until the reviewer explicitly reveals it.",
    input: { session_id: 27, event: { type: "text", target: "input#token", text: "secret-access-token" } },
    parsedResult: { delivered: true, event: { type: "text", target: "input#token", text: "secret-access-token" } }
  },
  {
    id: "failed_delivery",
    label: "Failed input delivery",
    description: "A provider error and undelivered result use the failure presentation.",
    input: { session_id: 27, event: { type: "click", x: 184, y: 72, pointer_type: "touch" } },
    parsedResult: { delivered: false, error: "lease_required", message: "Acquire an input lease before sending events." }
  }
]
