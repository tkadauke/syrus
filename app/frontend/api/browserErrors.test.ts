import { afterEach, describe, expect, it } from "vitest"
import { browserErrorRouteContext, buildBrowserErrorPayload } from "./browserErrors"

describe("browserErrorRouteContext", () => {
  it("identifies job routes with params" , () => {
    expect(browserErrorRouteContext("/jobs/3188")).toEqual({
      route_id: "job.show",
      route_params: { id: "3188" }
    })
    expect(browserErrorRouteContext("/jobs/3188/source")).toEqual({
      route_id: "job.source",
      route_params: { id: "3188" }
    })
  })

  it("identifies chat and admin routes" , () => {
    expect(browserErrorRouteContext("/chats/136")).toEqual({
      route_id: "chat.show",
      route_params: { id: "136" }
    })
    expect(browserErrorRouteContext("/admin/browser_errors")).toEqual({
      route_id: "admin.browser_errors",
      route_params: {}
    })
  })

  it("redacts sensitive route params" , () => {
    expect(browserErrorRouteContext("/chats/shared/share-token")).toEqual({
      route_id: "chat.shared",
      route_params: { token: "[FILTERED]" }
    })
    expect(browserErrorRouteContext("/passwords/reset-token/edit")).toEqual({
      route_id: "password.reset",
      route_params: { token: "[FILTERED]" }
    })
  })

  it("returns empty context for unknown paths" , () => {
    expect(browserErrorRouteContext("/unknown/path")).toEqual({})
  })
})

describe("buildBrowserErrorPayload", () => {
  afterEach(() => {
    window.history.replaceState(null, "", "/")
  })

  it("strips query strings and sensitive path tokens from stored location fields" , () => {
    window.history.replaceState(null, "", "/chats/shared/share-token?api_key=lin_api_secret")

    const payload = buildBrowserErrorPayload(new Error("boom"), {
      boundary: "test",
      fingerprint: "abc"
    })

    expect(payload.url).toBe("http://localhost:3000/chats/shared/[FILTERED]")
    expect(payload.path).toBe("/chats/shared/[FILTERED]")
    expect(payload.route_params).toEqual({ token: "[FILTERED]" })
  })
})
