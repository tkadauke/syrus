import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { parseSshExecCard, SshExecCardBody, sshExecSummary } from "../credentialStoreSshExecCard"

const card: ToolCardRenderer = {
  toolName: "credential_store_ssh_exec",
  collapsedSummary: sshExecSummary,
  renderExpanded(context: ToolCardContext) {
    const parsed = parseSshExecCard(context)
    return parsed ? <SshExecCardBody card={parsed} /> : null
  }
}

export default card
