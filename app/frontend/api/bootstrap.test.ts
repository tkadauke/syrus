import { afterEach, describe, expect, it, vi } from "vitest"
import { fetchBootstrap, readInitialBootstrap } from "./bootstrap"

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
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify({ error: { message: "bootstrap unavailable" } }), {
      status: 503,
      headers: { "Content-Type": "application/json", "X-Request-Id": "request-123" }
    }))

    await expect(fetchBootstrap()).rejects.toThrow("bootstrap unavailable")

    expect(mark).toHaveBeenCalledWith("bootstrap_fetch_started")
    expect(fail).toHaveBeenCalledWith(
      "bootstrap_fetch",
      expect.objectContaining({ message: "bootstrap unavailable" }),
      { request_correlation: expect.objectContaining({ path: "/api/v1/app/bootstrap", requestId: "request-123", status: 503 }) }
    )
    delete window.SyrusStartupDiagnostics
  })
})
