import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"

function credentialCount(context: ToolCardContext): number | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.credentials)) return null
  return parsed.credentials.length
}

const credentialStoreListCredentialsToolCard: ToolCardRenderer = {
  toolName: "credential_store_list_credentials",
  readOnly: true,
  collapsedSummary(context) {
    const count = credentialCount(context)
    return count == null ? null : String(count)
  },
  renderExpanded() {
    // The generic JSON body is intentional: every returned field is safe
    // discovery metadata, and keeping it visible helps agents plan usage.
    return null
  }
}

export default credentialStoreListCredentialsToolCard
