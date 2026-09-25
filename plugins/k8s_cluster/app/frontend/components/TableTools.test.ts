import { describe, expect, it } from "vitest"
import { matchesSearch } from "./TableTools"

describe("matchesSearch", () => {
  it("matches case-insensitively across any of the haystacks", () => {
    expect(matchesSearch("WEB", "web-1", "default")).toBe(true)
    expect(matchesSearch("sys", "web-1", "kube-system")).toBe(true)
    expect(matchesSearch("zzz", "web-1", "default")).toBe(false)
  })

  it("treats a blank query as matching everything", () => {
    expect(matchesSearch("", "web-1", "default")).toBe(true)
    expect(matchesSearch("   ", "web-1", "default")).toBe(true)
  })

  it("skips null and undefined haystacks", () => {
    expect(matchesSearch("web", null, undefined, "web-1")).toBe(true)
    expect(matchesSearch("web", null, undefined)).toBe(false)
  })
})
