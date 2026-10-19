import { pendingActionToolCard } from "../pendingActionToolCard"

const adminKillProcessToolCard = pendingActionToolCard("admin_kill_process", {
  inputFields: [
    { key: "process_id", label: "Process", format: "badge" },
    { key: "process_ids", label: "Processes", format: "list" }
  ]
})

export default adminKillProcessToolCard
