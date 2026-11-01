import { describe, expect, it, beforeAll } from "vitest"
import { readFileSync } from "node:fs"

// Exercises the policy the worker actually ships rather than a transcription
// of it: the ERB template is read from disk, its ERB tags stripped, and the
// script evaluated against a stub `self`. If the worker's rules change, these
// change with it -- which is the whole point, because the failure this guards
// against is a 502 reaching an installed PWA that has no way to retry.
type FallbackPolicy = (
  request: { mode?: string } | null,
  response: { status: number } | null,
  error: unknown
) => boolean

let shouldServeFallback: FallbackPolicy
const SERVICE_WORKER_TEMPLATE_PATH = "app/views/pwa/service_worker.js.erb"

beforeAll(() => {
  const template = readFileSync(SERVICE_WORKER_TEMPLATE_PATH, "utf-8")
  const source = template.replace(/<%=.*?%>/g, "stub")
  const scope: Record<string, unknown> = {}
  // The worker's top level only defines things and calls addEventListener, so
  // stubbing that plus `caches` is enough to evaluate it safely here.
  const self = new Proxy(scope, {
    get(target, prop) {
      if (prop === "addEventListener") return () => undefined
      return target[prop as string]
    },
    set(target, prop, value) {
      target[prop as string] = value
      return true
    }
  })
  new Function("self", "caches", source)(self, { open: () => Promise.resolve({}) })
  shouldServeFallback = scope.__syrusShouldServeFallback as FallbackPolicy
  expect(typeof shouldServeFallback).toBe("function")
})

describe("service worker fallback policy", () => {
  it("serves the fallback for a navigation that hits a gateway error", () => {
    for (const status of [ 502, 503, 504 ]) {
      expect(shouldServeFallback({ mode: "navigate" }, { status }, null)).toBe(true)
    }
  })

  it("serves the fallback for a navigation that could not reach a server at all", () => {
    expect(shouldServeFallback({ mode: "navigate" }, null, new Error("offline"))).toBe(true)
  })

  // The app's own 500 page is more informative than a "getting ready" spinner
  // that will never resolve, so an application error is not ours to swallow.
  it("passes an application 500 through to the app", () => {
    expect(shouldServeFallback({ mode: "navigate" }, { status: 500 }, null)).toBe(false)
  })

  it("passes successful navigations through untouched", () => {
    for (const status of [ 200, 302, 404 ]) {
      expect(shouldServeFallback({ mode: "navigate" }, { status }, null)).toBe(false)
    }
  })

  // Asset and API requests must never be intercepted — that is what keeps a
  // digested bundle from being pinned to a build that no longer exists.
  it("never intercepts anything that is not a navigation", () => {
    for (const mode of [ "cors", "no-cors", "same-origin" ]) {
      expect(shouldServeFallback({ mode }, { status: 502 }, null)).toBe(false)
      expect(shouldServeFallback({ mode }, null, new Error("offline"))).toBe(false)
    }
  })

  it("caches nothing but the fallback document", () => {
    const template = readFileSync(SERVICE_WORKER_TEMPLATE_PATH, "utf-8")
    // One cache.add, of the fallback, and no precache manifest or asset globs.
    expect(template.match(/cache\.add/g) ?? []).toHaveLength(1)
    expect(template).not.toMatch(/addAll|\.css|\.js["']|assets\//)
  })
})
