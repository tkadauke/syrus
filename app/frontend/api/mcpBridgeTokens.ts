import { deleteJson, getJson, postJson } from "./client"

export interface McpBridgeToken {
  id: number
  name: string
  token_prefix: string
  chat_id: number | null
  last_used_at: string | null
  revoked_at: string | null
  created_at: string | null
}

export interface IssuedMcpBridgeToken {
  token: McpBridgeToken
  plaintext: string
  endpoint: string
}

const BASE = "/api/v1/app/mcp_bridge_tokens"

export function fetchMcpBridgeTokens() {
  return getJson<{ tokens: McpBridgeToken[] }>(BASE)
}

export function issueMcpBridgeToken(name: string) {
  return postJson<IssuedMcpBridgeToken>(BASE, { name })
}

export function revokeMcpBridgeToken(id: number) {
  return deleteJson<{ token: McpBridgeToken }>(`${BASE}/${id}`)
}
