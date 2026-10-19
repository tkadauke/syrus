import { pendingActionToolCard } from "../pendingActionToolCard"

const adminPauseUserSchedulingToolCard = pendingActionToolCard("admin_pause_user_scheduling", {
  inputFields: [
    { key: "user_id", label: "User", format: "badge" },
    { key: "user_ids", label: "Users", format: "list" },
    { key: "reason", format: "markdown" }
  ]
})

export default adminPauseUserSchedulingToolCard
