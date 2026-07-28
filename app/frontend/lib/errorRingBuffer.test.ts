import { beforeEach, describe, expect, it } from "vitest"
import { _clearRecentErrors, getRecentErrors, initErrorRingBuffer } from "./errorRingBuffer"

describe("errorRingBuffer", () => {
  beforeEach(() => {
    _clearRecentErrors()
    initErrorRingBuffer()
  })

  it("starts empty", () => {
    expect(getRecentErrors()).toEqual([])
  })

  it("captures window.onerror events", () => {
    window.dispatchEvent(new ErrorEvent("error", { message: "Test error", filename: "app.js" }))

    const errors = getRecentErrors()
    expect(errors).toHaveLength(1)
    expect(errors[0]).toMatchObject({ message: "Test error", source: "app.js" })
    expect(errors[0].at).toMatch(/^\d{4}-\d{2}-\d{2}T/)
  })

  it("captures unhandledrejection with Error reason", () => {
    window.dispatchEvent(
      new PromiseRejectionEvent("unhandledrejection", {
        promise: Promise.resolve(),
        reason: new Error("Async failure")
      })
    )

    const errors = getRecentErrors()
    expect(errors).toHaveLength(1)
    expect(errors[0]).toMatchObject({ message: "Async failure", source: "promise" })
  })

  it("captures unhandledrejection with string reason", () => {
    window.dispatchEvent(
      new PromiseRejectionEvent("unhandledrejection", {
        promise: Promise.resolve(),
        reason: "plain string rejection"
      })
    )

    expect(getRecentErrors()[0]).toMatchObject({ message: "plain string rejection", source: "promise" })
  })

  it("caps at 10 errors, discarding the oldest", () => {
    for (let i = 0; i < 12; i++) {
      window.dispatchEvent(new ErrorEvent("error", { message: `error ${i}` }))
    }

    const errors = getRecentErrors()
    expect(errors).toHaveLength(10)
    expect(errors[0].message).toBe("error 2")
    expect(errors[9].message).toBe("error 11")
  })

  it("returns a copy so callers cannot mutate the internal buffer", () => {
    const snapshot = getRecentErrors()

    window.dispatchEvent(new ErrorEvent("error", { message: "new error" }))

    expect(snapshot).toHaveLength(0)
    expect(getRecentErrors()).toHaveLength(1)
  })

  it("truncates very long messages to 500 characters", () => {
    const longMessage = "x".repeat(600)
    window.dispatchEvent(new ErrorEvent("error", { message: longMessage }))

    expect(getRecentErrors()[0].message).toHaveLength(500)
  })

  it("is idempotent when called multiple times", () => {
    initErrorRingBuffer()
    initErrorRingBuffer()

    window.dispatchEvent(new ErrorEvent("error", { message: "once" }))

    expect(getRecentErrors()).toHaveLength(1)
  })
})
