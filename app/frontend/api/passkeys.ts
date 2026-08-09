import type { CredentialCreationOptionsJSON, PublicKeyCredentialWithAttestationJSON } from "@github/webauthn-json"
import { deleteJson, getJson, postJson } from "./client"

export type PasskeyRecord = {
  id: number
  nickname: string | null
  created_at: string
  last_used_at: string | null
}

export function fetchPasskeyRegistrationOptions() {
  return getJson<CredentialCreationOptionsJSON>("/api/v1/app/passkeys/registration_options")
}

export function registerPasskey(credential: PublicKeyCredentialWithAttestationJSON, nickname: string) {
  return postJson<PasskeyRecord>("/api/v1/app/passkeys/register", { credential, nickname })
}

export function fetchPasskeys() {
  return getJson<PasskeyRecord[]>("/api/v1/app/passkeys")
}

export function deletePasskey(id: number) {
  return deleteJson<void>(`/api/v1/app/passkeys/${id}`)
}
