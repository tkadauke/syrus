import type { ToolCardExample } from "@app/pluginToolCards"
import { runtimeToolCardRenderer } from "../runtimeToolCard"

export default runtimeToolCardRenderer("runtime_input")

export const examples: ToolCardExample[] = [
  {
    id: "typed_text_delivered",
    label: "Delivered typed text (redacted by default)",
    description: "Shows session and terminal event details, the default character-count mask, and the explicit reveal interaction.",
    input: {
      session_id: 27,
      event: {
        type: "stdin",
        target: "terminal",
        text: "A typed sentence for visual review."
      }
    },
    parsedResult: {
      delivered: true,
      event: {
        type: "stdin",
        target: "terminal",
        text: "A typed sentence for visual review."
      }
    },
    sourceType: "generic"
  },
  {
    id: "provider_error",
    label: "Provider rejected input",
    description: "Shows the failure tone, undelivered state, and separate provider error and message fields.",
    input: {
      session_id: 27,
      event: {
        type: "pointer",
        target: "button#save",
        x: 184,
        y: 72,
        button: 0,
        pointer_type: "touch"
      }
    },
    parsedResult: {
      delivered: false,
      error: "lease_required",
      message: "The agent must hold an active input lease before sending input events."
    },
    sourceType: "generic"
  }
]
