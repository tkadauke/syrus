import type { CredentialRequestOptionsJSON, PublicKeyCredentialWithAssertionJSON } from "@github/webauthn-json"
import { get } from "@github/webauthn-json"

export function isPasskeySupported(): boolean {
  return typeof window !== "undefined" &&
    !!window.PublicKeyCredential &&
    typeof navigator.credentials?.get === "function"
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
