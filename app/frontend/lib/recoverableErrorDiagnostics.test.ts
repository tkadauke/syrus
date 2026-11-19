import { afterEach, describe, expect, it, vi } from "vitest"
import {
  buildRecoverableErrorPayload,
  installRecoverableErrorInteractionCapture,
  nearbyResourceTimings,
  resetRecoverableErrorDiagnosticsForTest,
  semanticTarget
} from "./recoverableErrorDiagnostics"

afterEach(() => {
  resetRecoverableErrorDiagnosticsForTest()
  vi.restoreAllMocks()
  document.body.replaceChildren()
  window.history.replaceState(null, "", "/")
})

describe("recoverable error diagnostics", () => {
  it("captures only sanitized semantic interaction metadata", () => {
    window.history.replaceState(null, "", "/chats/shared/private-token?secret=hidden")
    document.body.innerHTML = '<button data-testid="send-control" type="submit">Secret draft text</button>'
    installRecoverableErrorInteractionCapture()
    document.querySelector("button")!.dispatchEvent(new MouseEvent("click", { bubbles: true }))

    const payload = buildRecoverableErrorPayload(new Error("recoverable"), { componentStack: "\n at ChatComposer" })
    expect(payload.component_stack).toBe("at ChatComposer")
    expect(payload.last_interaction).toMatchObject({
      event_type: "click",
      pathname: "/chats/shared/[FILTERED]",
      target: { tag: "button", test_id: "send-control", control_type: "submit" }
    })
    expect(JSON.stringify(payload.last_interaction)).not.toContain("Secret draft text")
    expect(JSON.stringify(payload.last_interaction)).not.toContain("private-token")
  })

  it("records an explicit component-stack reason and sanitizes the error cause", () => {
    const cause = new Error("chunk failed https://example.test/file.js?token=secret-value")
    const error = new Error("recoverable", { cause })
    const payload = buildRecoverableErrorPayload(error, {})

    expect(payload.component_stack).toBeUndefined()
    expect(payload.component_stack_unavailable_reason).toBe("React did not supply a component stack")
    expect(payload.error_cause?.message).toContain("?[FILTERED]")
    expect(payload.correlation_id).toBeTruthy()
    expect(payload.recoverable).toBe(true)
  })

  it("keeps only the eight most recent script and stylesheet resources without query strings", () => {
    const entries = Array.from({ length: 12 }, (_, index) => ({
      name: `http://localhost:3000/assets/chunk-${index}.js?token=secret`,
      initiatorType: index === 0 ? "img" : "script",
      startTime: index * 100,
      duration: 10,
      transferSize: 100,
      encodedBodySize: 80
    })) as PerformanceResourceTiming[]
    vi.spyOn(performance, "getEntriesByType").mockReturnValue(entries)

    const resources = nearbyResourceTimings(1_200)
    expect(resources).toHaveLength(8)
    expect(resources[0].name).toBe("http://localhost:3000/assets/chunk-11.js")
    expect(JSON.stringify(resources)).not.toContain("secret")
  })

  it("does not include form values or text in a semantic target", () => {
    const input = document.createElement("input")
    input.type = "password"
    input.value = "super-secret"
    input.setAttribute("aria-label", "Private label")
    expect(semanticTarget(input)).toEqual({ tag: "input", control_type: "password" })
  })
})
