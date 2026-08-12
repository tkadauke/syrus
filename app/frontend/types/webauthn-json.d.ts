import "@github/webauthn-json"

declare module "@github/webauthn-json" {
  export type PublicKeyCredentialCreationOptionsJSON = CredentialCreationOptionsJSON["publicKey"]
  export type PublicKeyCredentialRequestOptionsJSON = NonNullable<CredentialRequestOptionsJSON["publicKey"]>
}
