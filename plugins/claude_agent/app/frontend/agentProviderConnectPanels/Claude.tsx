import { ClaudeConnect } from "../components/credentials/ClaudeConnect"
import type { PluginAgentProviderConnectPanel } from "@app/pluginAgentProviderConnectPanels"

const panel: PluginAgentProviderConnectPanel = {
  provider: "claude",
  component: ClaudeConnect
}

export default panel
