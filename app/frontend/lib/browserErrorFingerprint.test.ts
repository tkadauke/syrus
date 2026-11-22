import { describe, expect, it } from "vitest"
import { computeBrowserErrorFingerprint } from "./browserErrorFingerprint"

describe("computeBrowserErrorFingerprint", () => {
  it("uses the full error payload instead of only a shared prefix", () => {
    const sharedPrefix = "x".repeat(512)
    const first = new Error(`${sharedPrefix} first distinct suffix`)
    const second = new Error(`${sharedPrefix} second distinct suffix`)

    first.stack = `${sharedPrefix}\nfirst stack suffix`
    second.stack = `${sharedPrefix}\nsecond stack suffix`

    expect(computeBrowserErrorFingerprint(first)).not.toEqual(computeBrowserErrorFingerprint(second))
  })

  it("does not encode filtered secrets in the fingerprint", () => {
    const first = new Error("upload failed https://example.test/file?token=first-secret")
    const second = new Error("upload failed https://example.test/file?token=second-secret")

    first.stack = "Error at /chats/shared/first-private-token"
    second.stack = "Error at /chats/shared/second-private-token"

    expect(computeBrowserErrorFingerprint(first)).toEqual(computeBrowserErrorFingerprint(second))
  })
})
