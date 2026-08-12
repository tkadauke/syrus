import { describe, expect, it, vi } from "vitest"

const create = vi.fn()
const get = vi.fn()

vi.mock("@github/webauthn-json", () => ({
  create: (...args: unknown[]) => create(...args),
  get: (...args: unknown[]) => get(...args)
}))

import { registerNewPasskey, signInWithPasskey } from "./passkey"

describe("registerNewPasskey", () => {
  it("wraps the fetched options in a publicKey key before calling create", async () => {
    const options = { challenge: "reg-challenge", rp: { name: "Syrus" } }
    const credential = { id: "cred-1" }
    create.mockResolvedValue(credential)
    const fetchOptions = vi.fn().mockResolvedValue(options)
    const submitRegistration = vi.fn().mockResolvedValue(undefined)

    await registerNewPasskey("My Key", fetchOptions, submitRegistration)

    expect(create).toHaveBeenCalledWith({ publicKey: options })
    expect(submitRegistration).toHaveBeenCalledWith(credential, "My Key")
  })
})

describe("signInWithPasskey", () => {
  it("wraps the fetched options in a publicKey key before calling get, and extracts the challenge from the unwrapped options", async () => {
    const options = { challenge: "auth-challenge" }
    const credential = { id: "cred-2" }
    get.mockResolvedValue(credential)
    const fetchOptions = vi.fn().mockResolvedValue(options)
    const submitAssertion = vi.fn().mockResolvedValue({ redirect_to: "/dashboard" })

    const redirectPath = await signInWithPasskey(fetchOptions, submitAssertion)

    expect(get).toHaveBeenCalledWith({ publicKey: options })
    expect(submitAssertion).toHaveBeenCalledWith(credential, "auth-challenge")
    expect(redirectPath).toBe("/dashboard")
  })
})
