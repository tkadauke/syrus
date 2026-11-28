import { describe, expect, it } from "vitest"
import { shouldRecoverStrandedUpdate } from "../electron/strandedUpdate"

describe("shouldRecoverStrandedUpdate", () => {
  const state = { updateBundleURL: "/staged/Syrus.app" }

  it("recovers when ShipIt has a newer bundle staged", () => {
    expect(shouldRecoverStrandedUpdate({ state, stagedVersion: "0.2.0", runningVersion: "0.1.9" })).toBe(true)
  })

  it("does nothing when the staged and running versions match", () => {
    expect(shouldRecoverStrandedUpdate({ state, stagedVersion: "0.2.0", runningVersion: "0.2.0" })).toBe(false)
  })

  it("does nothing without ShipIt state", () => {
    expect(shouldRecoverStrandedUpdate({ state: null, stagedVersion: "0.2.0", runningVersion: "0.1.9" })).toBe(false)
  })

  it("does nothing when the staged bundle is older or unreadable", () => {
    expect(shouldRecoverStrandedUpdate({ state, stagedVersion: "0.1.8", runningVersion: "0.1.9" })).toBe(false)
    expect(shouldRecoverStrandedUpdate({ state, stagedVersion: null, runningVersion: "0.1.9" })).toBe(false)
  })
})
