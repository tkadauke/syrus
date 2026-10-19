import { pendingActionToolCard } from "../pendingActionToolCard"

const wakeProviderAdmissionToolCard = pendingActionToolCard("wake_provider_admission", {
  inputFields: [
    { key: "provider", format: "badge" },
    { key: "user_id", label: "User", format: "badge" },
    { key: "reason", format: "markdown" }
  ]
})

export default wakeProviderAdmissionToolCard
