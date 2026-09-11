import { describe, expect, it } from "vitest"
import { redactToolCardText, redactToolCardValue, toolCardPayloadSizeLabel } from "./toolCardSecurity"

describe("toolCardSecurity", () => {
  it("redacts sensitive object keys recursively", () => {
    expect(redactToolCardValue({
      safe: "visible",
      api_token: "tok_live_123456789",
      accessToken: "access-secret-123456",
      nested: { password: "hunter2-secret", rows: [{ client_secret: "shh-123456", refreshToken: "refresh-secret-123456" }] }
    })).toEqual({
      safe: "visible",
      api_token: "[redacted]",
      accessToken: "[redacted]",
      nested: { password: "[redacted]", rows: [{ client_secret: "[redacted]", refreshToken: "[redacted]" }] }
    })
  })

  it("redacts inline token-like text", () => {
    expect(redactToolCardText("Authorization: Bearer abcdefghijklmnopqrstuvwxyz and password=hunter2-secret and accessToken=access-secret-123456")).toBe(
      "Authorization: Bearer [redacted] and password=[redacted] and accessToken=[redacted]"
    )
  })

  it("redacts camelCase token keys in JSON-ish text", () => {
    expect(redactToolCardText('{"accessToken":"access-secret-123456","safe":"visible"}')).toBe(
      '{"accessToken":"[redacted]","safe":"visible"}'
    )
  })

  it("reports payload size in bytes for small payloads", () => {
    expect(toolCardPayloadSizeLabel("abc")).toBe("3 B")
  })
})
