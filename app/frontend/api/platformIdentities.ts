import { deleteJson, getJson, postJson } from "./client"

export type PlatformIdentity = {
  id: number
  platform: string
  external_handle: string | null
  linked_at: string
}

export type AvailablePlatform = {
  platform: string
  label: string
  configured: boolean
}

export type PlatformIdentitiesPayload = {
  platform_identities: PlatformIdentity[]
  available_platforms: AvailablePlatform[]
  message?: string
}

export type LinkingTokenPayload = {
  token: string
  instructions: {
    text: string
    bot_handle?: string
  }
}

export function fetchPlatformIdentities() {
  return getJson<PlatformIdentitiesPayload>("/api/v1/app/platform_identities")
}

export function deletePlatformIdentity(id: number) {
  return deleteJson<PlatformIdentitiesPayload>(`/api/v1/app/platform_identities/${id}`)
}

export function createLinkingToken(platform: string) {
  return postJson<LinkingTokenPayload>("/api/v1/app/platform_identities/linking_token", { platform })
}
