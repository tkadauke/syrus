import { afterEach, describe, expect, it, vi } from "vitest"
import { fetchBootstrap, fetchBootstrapWithRetries, readInitialBootstrap } from "./bootstrap"

describe("readInitialBootstrap", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("returns null after a browser document has been torn down", () => {
    vi.stubGlobal("document", undefined)

    expect(readInitialBootstrap()).toBeNull()
  })
})

describe("fetchBootstrap", () => {
  afterEach(() => vi.restoreAllMocks())

  it("reports the causal error as a bootstrap startup failure", async () => {
    const fail = vi.fn()
    const mark = vi.fn()
    window.SyrusStartupDiagnostics = { fail, mark }
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "bootstrap unavailable" } }), {
        status: 503,
        headers: { "Content-Type": "application/json", "X-Request-Id": "request-123" }
      })
    )

    await expect(fetchBootstrap()).rejects.toThrow("bootstrap unavailable")

    expect(mark).toHaveBeenCalledWith("bootstrap_fetch_started")
    expect(fail).toHaveBeenCalledWith("bootstrap_fetch", expect.objectContaining({ message: "bootstrap unavailable" }), {
      request_correlation: expect.objectContaining({ path: "/api/v1/app/bootstrap", requestId: "request-123", status: 503 })
    })
    delete window.SyrusStartupDiagnostics
  })

  // Regression: a dropped request during a rollout or a suspended mobile tab
  // was reported as a failed startup even when the next attempt worked.
  it("retries a request that got no response before reporting a startup failure", async () => {
    const fail = vi.fn()
    window.SyrusStartupDiagnostics = { fail, mark: vi.fn() }
    vi.spyOn(window, "fetch")
      .mockRejectedValueOnce(new TypeError("Load failed"))
      .mockResolvedValueOnce(new Response(JSON.stringify({ csrf_token: "token" }), { status: 200, headers: { "Content-Type": "application/json" } }))
    const sleep = vi.fn().mockResolvedValue(undefined)

    await expect(fetchBootstrapWithRetries(sleep)).resolves.toMatchObject({ csrf_token: "token" })

    expect(sleep).toHaveBeenCalledTimes(1)
    expect(fail).not.toHaveBeenCalled()
    delete window.SyrusStartupDiagnostics
  })

  it("reports a startup failure once every network retry is spent", async () => {
    const fail = vi.fn()
    window.SyrusStartupDiagnostics = { fail, mark: vi.fn() }
    vi.spyOn(window, "fetch").mockRejectedValue(new TypeError("Load failed"))
    const sleep = vi.fn().mockResolvedValue(undefined)

    await expect(fetchBootstrapWithRetries(sleep)).rejects.toThrow("Load failed")

    expect(sleep).toHaveBeenCalledTimes(2)
    expect(fail).toHaveBeenCalledTimes(1)
    delete window.SyrusStartupDiagnostics
  })
})
