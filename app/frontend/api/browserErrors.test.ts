import { describe, expect, it } from "vitest"
import { browserErrorRouteContext } from "./browserErrors"

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

  it("returns empty context for unknown paths" , () => {
    expect(browserErrorRouteContext("/unknown/path")).toEqual({})
  })
})
