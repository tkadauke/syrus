import { describe, expect, it } from "vitest"
import { redactToolCardText, redactToolCardValue, toolCardPayloadSizeLabel } from "./toolCardSecurity"

describe("toolCardSecurity", () => {
  it("redacts sensitive object keys recursively", () => {
    expect(redactToolCardValue({
      safe: "visible",
      api_token: "tok_live_123456789",
      nested: { password: "hunter2-secret", rows: [{ client_secret: "shh-123456" }] }
    })).toEqual({
      safe: "visible",
      api_token: "[redacted]",
      nested: { password: "[redacted]", rows: [{ client_secret: "[redacted]" }] }
    })
  })

  it("redacts inline token-like text", () => {
    expect(redactToolCardText("Authorization: Bearer abcdefghijklmnopqrstuvwxyz and password=hunter2-secret")).toBe(
      "Authorization: Bearer [redacted] and password=[redacted]"
    )
  })

  it("reports payload size in bytes for small payloads", () => {
    expect(toolCardPayloadSizeLabel("abc")).toBe("3 B")
  })
})
