import type { PublicKeyCredentialRequestOptionsJSON, PublicKeyCredentialWithAssertionJSON } from "@github/webauthn-json"
import { getJson, patchJson, postJson } from "./client"

export type SignupPayload = {
  allowed: boolean
  first_signup: boolean
  signups_open: boolean
  invitation: {
    token: string
    email_address: string
    invited_by_email: string
  } | null
}

export type PublicAuthStatusPayload = {
  authenticated: boolean
  first_signup: boolean
  signups_open: boolean
  valid_invitation: boolean
  cta: {
    kind: "dashboard" | "create_first_account" | "sign_up" | "accept_invitation" | "sign_in"
    label: string
    href: string
  }
}

export type AuthRedirectPayload = {
  redirect_to: string
  message?: string
}

export type PasswordRequestPayload = {
  message: string
  redirect_to: string
}

export function fetchSignup(search = "") {
  return getJson<SignupPayload>(`/api/v1/app/auth/signup${search}`)
}

export function fetchPublicAuthStatus(search = "") {
  return getJson<PublicAuthStatusPayload>(`/api/v1/app/auth/status${search}`)
}

export function signIn(values: { email_address: string; password: string }) {
  return postJson<AuthRedirectPayload>("/api/v1/app/auth/session", values)
}

export function signUp(values: {
  email_address: string
  password: string
  password_confirmation: string
  invitation_token?: string
}) {
  return postJson<AuthRedirectPayload>("/api/v1/app/auth/users", { user: values })
}

export function requestPasswordReset(emailAddress: string) {
  return postJson<PasswordRequestPayload>("/api/v1/app/auth/passwords", { email_address: emailAddress })
}

export function resetPassword(token: string, values: { password: string; password_confirmation: string }) {
  return patchJson<AuthRedirectPayload>(`/api/v1/app/auth/passwords/${encodeURIComponent(token)}`, values)
}

export function fetchPasskeyAuthenticationOptions() {
  return getJson<PublicKeyCredentialRequestOptionsJSON>("/api/v1/app/passkeys/authentication_options")
}

export function authenticateWithPasskey(credential: PublicKeyCredentialWithAssertionJSON, challenge: string) {
  return postJson<AuthRedirectPayload>("/api/v1/app/passkeys/authenticate", { credential, challenge })
}
