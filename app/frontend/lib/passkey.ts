import type { PublicKeyCredentialCreationOptionsJSON, PublicKeyCredentialRequestOptionsJSON, PublicKeyCredentialWithAssertionJSON, PublicKeyCredentialWithAttestationJSON } from "@github/webauthn-json"
import { create, get } from "@github/webauthn-json"

export function isPasskeySupported(): boolean {
  return typeof window !== "undefined" &&
    !!window.PublicKeyCredential &&
    typeof navigator.credentials?.get === "function"
}

export async function registerNewPasskey(
  nickname: string,
  fetchOptions: () => Promise<PublicKeyCredentialCreationOptionsJSON>,
  submitRegistration: (cred: PublicKeyCredentialWithAttestationJSON, nickname: string) => Promise<unknown>
): Promise<void> {
  const options = await fetchOptions()
  const credential = await create({ publicKey: options })
  await submitRegistration(credential, nickname)
}

export async function signInWithPasskey(
  fetchOptions: () => Promise<PublicKeyCredentialRequestOptionsJSON>,
  submitAssertion: (cred: PublicKeyCredentialWithAssertionJSON, challenge: string) => Promise<{ redirect_to: string }>
): Promise<string> {
  const options = await fetchOptions()
  const credential = await get({ publicKey: options })
  const { redirect_to } = await submitAssertion(credential, options.challenge)
  return redirect_to
}
