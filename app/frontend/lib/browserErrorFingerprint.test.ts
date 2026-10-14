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
})
