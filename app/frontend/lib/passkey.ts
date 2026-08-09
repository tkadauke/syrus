import type { CredentialCreationOptionsJSON, CredentialRequestOptionsJSON, PublicKeyCredentialWithAssertionJSON, PublicKeyCredentialWithAttestationJSON } from "@github/webauthn-json"
import { create, get } from "@github/webauthn-json"

export function isPasskeySupported(): boolean {
  return typeof window !== "undefined" &&
    !!window.PublicKeyCredential &&
    typeof navigator.credentials?.get === "function"
}

export async function registerNewPasskey(
  nickname: string,
  fetchOptions: () => Promise<CredentialCreationOptionsJSON>,
  submitRegistration: (cred: PublicKeyCredentialWithAttestationJSON, nickname: string) => Promise<unknown>
): Promise<void> {
  const options = await fetchOptions()
  const credential = await create(options)
  await submitRegistration(credential, nickname)
}

export async function signInWithPasskey(
  fetchOptions: () => Promise<CredentialRequestOptionsJSON>,
  submitAssertion: (cred: PublicKeyCredentialWithAssertionJSON) => Promise<{ redirect_to: string }>
): Promise<string> {
  const options = await fetchOptions()
  const credential = await get(options)
  const { redirect_to } = await submitAssertion(credential)
  return redirect_to
}
