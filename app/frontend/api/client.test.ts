import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"

const reloadPageMock = vi.hoisted(() => vi.fn())

vi.mock("../lib/pageReload", () => ({
  reloadPage: reloadPageMock
}))

describe("API revision reload guard", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    reloadPageMock.mockClear()
    window.sessionStorage.clear()
    document.getElementById("syrus-bootstrap-data")?.remove()
    vi.resetModules()
  })

  it("does not reload when the backend revision matches the embedded frontend revision", async () => {
    const { getJson } = await import("./client")
    installBootstrapRevision("abc123")
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponseWithRevision({ ok: true }, "abc123"))

    await expect(getJson("/api/v1/app/bootstrap")).resolves.toEqual({ ok: true })

    expect(reloadPageMock).not.toHaveBeenCalled()
  })

  it("reloads once when an API response comes from a newer backend revision", async () => {
    const { getJson } = await import("./client")
    installBootstrapRevision("old123")
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponseWithRevision({ ok: true }, "new456")))

    await expect(getJson("/api/v1/app/bootstrap")).resolves.toEqual({ ok: true })
    await expect(getJson("/api/v1/app/dashboard")).resolves.toEqual({ ok: true })

    expect(reloadPageMock).toHaveBeenCalledTimes(1)
  })
})

describe("401 sign-in redirect", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
    vi.resetModules()
  })

  it("sends the browser to sign in when a request is unauthorized", async () => {
    const assign = stubLocation("/dashboard")
    const { getJson } = await import("./client")
    vi.spyOn(window, "fetch").mockResolvedValue(unauthorizedResponse())

    await expect(getJson("/api/v1/app/maintenance_tasks/sidebar")).rejects.toThrow()

    expect(assign).toHaveBeenCalledWith("/session/new")
  })

  // The log storm: assign() to the current URL is a reload, so an authenticated
  // query left mounted on the sign-in page loops 401 -> reload -> remount -> 401
  // at browser speed. A logged-out tab held ~26 requests/second this way.
  it("does not redirect when the browser is already on the sign-in page", async () => {
    const assign = stubLocation("/session/new")
    const { getJson } = await import("./client")
    vi.spyOn(window, "fetch").mockResolvedValue(unauthorizedResponse())

    await expect(getJson("/api/v1/app/maintenance_tasks/sidebar")).rejects.toThrow()

    expect(assign).not.toHaveBeenCalled()
  })

  it("recognizes the sign-in page under the desktop shell mount", async () => {
    const assign = stubLocation("/app-shell/session/new")
    const { getJson } = await import("./client")
    vi.spyOn(window, "fetch").mockResolvedValue(unauthorizedResponse())

    await expect(getJson("/api/v1/app/maintenance_tasks/sidebar")).rejects.toThrow()

    expect(assign).not.toHaveBeenCalled()
  })

  it("still reports the error so callers can render it", async () => {
    stubLocation("/dashboard")
    const { getJson } = await import("./client")
    vi.spyOn(window, "fetch").mockResolvedValue(unauthorizedResponse())

    await expect(getJson("/api/v1/app/chats")).rejects.toMatchObject({ status: 401 })
  })
})

function stubLocation(pathname: string) {
  const assign = vi.fn()
  vi.stubGlobal("location", { ...window.location, pathname, assign })
  return assign
}

function unauthorizedResponse() {
  return new Response(JSON.stringify({ error: { message: "Unauthorized" } }), {
    status: 401,
    headers: { "Content-Type": "application/json" }
  })
}

function installBootstrapRevision(revision: string) {
  const script = document.createElement("script")
  script.id = "syrus-bootstrap-data"
  script.type = "application/json"
  script.textContent = JSON.stringify({ app: { revision } })
  document.body.appendChild(script)
}

function jsonResponseWithRevision(body: unknown, revision: string) {
  const response = jsonResponse(body)
  response.headers.set("X-Syrus-Revision", revision)
  return response
}
