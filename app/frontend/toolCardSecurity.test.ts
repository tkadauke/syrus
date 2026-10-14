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

  it("redacts environment-style secret assignments with prefixed key names", () => {
    expect(redactToolCardText([
      "DATABASE_PASSWORD=hunter2hunter2",
      "MY_API_KEY=abcdef123456789",
      "export GITHUB_TOKEN=abcdef123456",
      "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "SECRET_KEY_BASE=0123456789abcdef0123456789abcdef"
    ].join("\n"))).toBe([
      "DATABASE_PASSWORD=[redacted]",
      "MY_API_KEY=[redacted]",
      "export GITHUB_TOKEN=[redacted]",
      "AWS_SECRET_ACCESS_KEY=[redacted]",
      "SECRET_KEY_BASE=[redacted]"
    ].join("\n"))
  })

  it("redacts entire quoted secret assignment values", () => {
    expect(redactToolCardText('password = "hunter two"')).toBe(
      'password = "[redacted]"'
    )
  })

  it("redacts camelCase token keys in JSON-ish text", () => {
    expect(redactToolCardText('{"accessToken":"access-secret-123456","safe":"visible"}')).toBe(
      '{"accessToken":"[redacted]","safe":"visible"}'
    )
  })

  it("redacts bare secret-like values from compact detail strings", () => {
    expect(redactToolCardText("plugin-input-secret-123456")).toBe("[redacted]")
  })

  it("reports payload size in bytes for small payloads", () => {
    expect(toolCardPayloadSizeLabel("abc")).toBe("3 B")
  })
})
