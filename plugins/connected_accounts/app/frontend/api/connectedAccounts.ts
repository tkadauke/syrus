import { deleteJson, getJson, postJson } from "@app/api/client"

export type OAuthProvider = {
  id: number
  key: string
  display_name: string
  authorize_url: string
  token_url: string
  revoke_url: string | null
  identity_url: string | null
  scopes: string[]
  api_origins: string[]
}

const BASE = "/api/v1/app/admin/connected_account_providers"
export const fetchProviders = () => getJson<{ providers: OAuthProvider[] }>(BASE)
export const createProvider = (provider: Record<string, unknown>) => postJson<{ provider: OAuthProvider }>(BASE, provider)
export const deleteProvider = (id: number) => deleteJson<void>(`${BASE}/${id}`)
