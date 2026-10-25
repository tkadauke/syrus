import i18n from "../../../i18n"
import type { ToolCardExample } from "@app/pluginToolCards"
import { pendingActionToolCard } from "../pendingActionToolCard"

// Pending-action tool card (the pending-action tool-card work). All of the parsing and
// presentation lives in ../pendingActionToolCard so the whole family stays
// consistent; this file only binds it to one MCP tool name.
const adminKillProcessToolCard = pendingActionToolCard("admin_kill_process", {
  inputFields: [
    { key: "process_id", label: () => i18n.t("chat:ops_process_12f4c1"), format: "entity", hrefPrefix: "/admin/processes" },
    { key: "process_ids", label: () => i18n.t("chat:ops_processes_ed7308"), format: "entity_list", hrefPrefix: "/admin/processes" }
  ]
})

export const examples: ToolCardExample[] = [
  {
    id: "bulk_process_targets",
    label: i18n.t("chat:ops_bulk_process_targets_aaa2e9"),
    description: i18n.t("chat:ops_shows_the_concrete_linked_process_targets_for_a_grouped__0c0e4e"),
    input: { process_ids: [41, 42, 43] },
    parsedResult: {
      pending_action_group_id: 88,
      pending_action_id: 501,
      pending_confirmation_id: 501,
      state: "pending",
      member_count: 3,
      message: i18n.t("chat:admin_kill_process_confirmation", { count: 3, targets: i18n.t("chat:admin_kill_process_catalog_targets") })
    }
  }
]

export default adminKillProcessToolCard
