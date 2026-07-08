import { describe, expect, it } from "vitest"
import { resolveInstanceOrigin, resolveOpenInSyrusTarget } from "../electron/windows/openInSyrusTarget"

const serverUrl = "http://localhost:3000"

describe("resolveInstanceOrigin", () => {
  it("returns the configured instance's web origin", () => {
    expect(resolveInstanceOrigin("http://localhost:3000")).toBe("http://localhost:3000")
    expect(resolveInstanceOrigin("https://syrus.example.com")).toBe("https://syrus.example.com")
  })

  it("normalizes trailing slashes and whitespace", () => {
    expect(resolveInstanceOrigin("http://localhost:3000/")).toBe("http://localhost:3000")
    expect(resolveInstanceOrigin("  https://syrus.example.com//  ")).toBe("https://syrus.example.com")
  })

  it("drops any path — origins compare scheme, host, and port only", () => {
    expect(resolveInstanceOrigin("https://syrus.example.com/app")).toBe("https://syrus.example.com")
  })

  it("returns null when no instance is configured or the URL is unparseable", () => {
    // Callers (shell:* sender validation, the Open-in-Syrus resolver) treat
    // null as "trust nothing" — a missing origin must never match anything.
    expect(resolveInstanceOrigin("")).toBeNull()
    expect(resolveInstanceOrigin("   ")).toBeNull()
    expect(resolveInstanceOrigin("not a url")).toBeNull()
  })
})

describe("resolveOpenInSyrusTarget", () => {
  it("resolves instance-relative paths against the server URL", () => {
    expect(resolveOpenInSyrusTarget(serverUrl, "/jobs/12")).toBe("http://localhost:3000/jobs/12")
  })

  it("keeps query strings and fragments (chat message anchors)", () => {
    expect(resolveOpenInSyrusTarget(serverUrl, "/app-shell/chats/7#message-42")).toBe(
      "http://localhost:3000/app-shell/chats/7#message-42"
    )
  })

  it("accepts full same-origin URLs (toast actionUrl carries them)", () => {
    expect(resolveOpenInSyrusTarget(serverUrl, "http://localhost:3000/jobs/9")).toBe(
      "http://localhost:3000/jobs/9"
    )
  })

  it("tolerates a trailing slash on the configured server URL", () => {
    expect(resolveOpenInSyrusTarget("http://localhost:3000/", "/jobs/12")).toBe(
      "http://localhost:3000/jobs/12"
    )
  })

  it("refuses cross-origin targets — the app window is never steered off-instance", () => {
    expect(resolveOpenInSyrusTarget(serverUrl, "https://github.com/tkadauke/syrus/pull/1")).toBeNull()
    expect(resolveOpenInSyrusTarget(serverUrl, "http://localhost:4000/jobs/1")).toBeNull()
    expect(resolveOpenInSyrusTarget(serverUrl, "https://localhost:3000/jobs/1")).toBeNull()
  })

  it("returns null when no instance is configured or the target is empty", () => {
    expect(resolveOpenInSyrusTarget("", "/jobs/12")).toBeNull()
    expect(resolveOpenInSyrusTarget(serverUrl, "")).toBeNull()
    expect(resolveOpenInSyrusTarget(serverUrl, "   ")).toBeNull()
  })
})
