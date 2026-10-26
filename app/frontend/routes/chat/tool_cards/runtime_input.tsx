import i18n from "@app/i18n"
import type { ToolCardExample } from "@app/pluginToolCards"
import { runtimeToolCardRenderer } from "../runtimeToolCard"

export default runtimeToolCardRenderer("runtime_input")

export const examples: ToolCardExample[] = [
  {
    id: "redacted_typed_input",
    label: i18n.t("chat:runtime_input_example_redacted"),
    description: i18n.t("chat:runtime_input_example_redacted_description"),
    input: { session_id: 27, event: { type: "text", target: "input#token", text: "secret-access-token" } },
    parsedResult: { delivered: true, event: { type: "text", target: "input#token", text: "secret-access-token" } }
  },
  {
    id: "failed_delivery",
    label: i18n.t("chat:runtime_input_example_failed"),
    description: i18n.t("chat:runtime_input_example_failed_description"),
    input: { session_id: 27, event: { type: "click", x: 184, y: 72, pointer_type: "touch" } },
    parsedResult: { delivered: false, error: "lease_required", message: i18n.t("chat:runtime_input_example_lease_required") }
  }
]
