import { describe, expect, it, beforeAll, vi } from "vitest"
import template from "../../views/pwa/service_worker.js.erb?raw"

// Exercises the policy the worker actually ships rather than a transcription
// of it: the ERB template is read from disk, its ERB tags stripped, and the
// script evaluated against a stub `self`. If the worker's rules change, these
// change with it -- which is the whole point, because the failure this guards
// against is a 502 reaching an installed PWA that has no way to retry.
type FallbackPolicy = (request: { mode?: string } | null, response: { status: number } | null, error: unknown) => boolean

type FakeClient = { id: string; postMessage: ReturnType<typeof vi.fn> }
type StartupAssetProgress = {
  shouldCountAsset: (request: Request) => boolean
  countedResponse: (response: Response, onProgress: (loaded: number, done: boolean) => void) => Response
  countAssetFetch: (event: { request: Request; clientId?: string; resultingClientId?: string }) => Promise<Response>
  PROGRESS_MESSAGE_TYPE: string
}

const ORIGIN = "https://syrus.test"

function loadWorker(options: { fetch?: typeof fetch; clients?: FakeClient[]; caches?: Record<string, unknown> } = {}) {
  const source = template.replace(/<%=.*?%>/g, "stub")
  const scope: Record<string, unknown> = {}
  const listeners: Record<string, (event: unknown) => void> = {}
  const clients = options.clients ?? []
  scope.location = new URL(`${ORIGIN}/service-worker.js`)
  scope.clients = {
    get: vi.fn((id: string) => Promise.resolve(clients.find((client) => client.id === id))),
    matchAll: vi.fn(() => Promise.resolve(clients))
  }
  // The worker's top level only defines things and calls addEventListener, so
  // stubbing that plus `caches` is enough to evaluate it safely here.
  const self = new Proxy(scope, {
    get(target, prop) {
      if (prop === "addEventListener") return (type: string, listener: (event: unknown) => void) => { listeners[type] = listener }
      return target[prop as string]
    },
    set(target, prop, value) {
      target[prop as string] = value
      return true
    }
  })
  const caches = options.caches ?? { open: () => Promise.resolve({}) }
  const fetchImpl = options.fetch ?? vi.fn()
  new Function("self", "caches", "fetch", source)(self, caches, fetchImpl)
  return { scope, listeners, fetch: fetchImpl }
}

let shouldServeFallback: FallbackPolicy
beforeAll(() => {
  const { scope } = loadWorker()
  shouldServeFallback = scope.__syrusShouldServeFallback as FallbackPolicy
  expect(typeof shouldServeFallback).toBe("function")
})

describe("service worker fallback policy", () => {
  it("serves the fallback for a navigation that hits a gateway error", () => {
    for (const status of [502, 503, 504]) {
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
    for (const status of [200, 302, 404]) {
      expect(shouldServeFallback({ mode: "navigate" }, { status }, null)).toBe(false)
    }
  })

  // Asset and API requests must never get the fallback document — that is
  // what keeps a digested bundle from being pinned to a build that no longer
  // exists.
  it("never serves the fallback for anything that is not a navigation", () => {
    for (const mode of ["cors", "no-cors", "same-origin"]) {
      expect(shouldServeFallback({ mode }, { status: 502 }, null)).toBe(false)
      expect(shouldServeFallback({ mode }, null, new Error("offline"))).toBe(false)
    }
  })

  it("caches nothing but the fallback document", () => {
    // One cache.add, of the fallback, and no precache manifest, cache.put, or
    // asset globs.
    expect(template.match(/cache\.add/g) ?? []).toHaveLength(1)
    expect(template).not.toMatch(/addAll|cache\.put|\.put\(/)
  })
})

describe("service worker startup asset progress", () => {
  const ENTRY = `${ORIGIN}/assets/spa-entry-AbC_12-x.digested.js`

  function bodyStream(chunks: string[]): ReadableStream<Uint8Array> {
    const encoder = new TextEncoder()
    return new ReadableStream({
      start(controller) {
        chunks.forEach((chunk) => controller.enqueue(encoder.encode(chunk)))
        controller.close()
      }
    })
  }

  function progress(worker: ReturnType<typeof loadWorker>) {
    return worker.scope.__syrusStartupAssetProgress as StartupAssetProgress
  }

  function fetchEvent(request: Request, extra: Record<string, unknown> = {}) {
    const respondWith = vi.fn()
    return { event: { request, respondWith, ...extra }, respondWith }
  }

  it("counts only same-origin GETs of digested scripts and stylesheets", () => {
    const { shouldCountAsset } = progress(loadWorker())

    expect(shouldCountAsset(new Request(ENTRY))).toBe(true)
    expect(shouldCountAsset(new Request(`${ORIGIN}/assets/tailwind-74e6a7ef.css`))).toBe(true)
    expect(shouldCountAsset(new Request(`${ORIGIN}/assets/spa-vendor-DuQfn8Z1.digested.css`))).toBe(true)

    expect(shouldCountAsset(new Request(ENTRY, { method: "POST", body: "x" }))).toBe(false)
    expect(shouldCountAsset(new Request(ENTRY, { method: "HEAD" }))).toBe(false)
    expect(shouldCountAsset(new Request(ENTRY, { headers: { Range: "bytes=0-10" } }))).toBe(false)
    expect(shouldCountAsset(new Request(`https://cdn.example/assets/spa-entry-AbC_12-x.digested.js`))).toBe(false)
    expect(shouldCountAsset(new Request(`${ORIGIN}/assets/startup_diagnostics.js`))).toBe(false)
    expect(shouldCountAsset(new Request(`${ORIGIN}/assets/icon-74e6a7ef.png`))).toBe(false)
    expect(shouldCountAsset(new Request(`${ORIGIN}/api/v1/app/bootstrap`))).toBe(false)
    expect(shouldCountAsset(new Request(`${ORIGIN}/jobs/42`))).toBe(false)
  })

  it("leaves requests it does not count to the browser", () => {
    const worker = loadWorker()
    for (const request of [
      new Request(`${ORIGIN}/api/v1/app/bootstrap`),
      new Request(ENTRY, { method: "POST", body: "x" }),
      new Request(`https://cdn.example/assets/spa-entry-AbC_12-x.digested.js`)
    ]) {
      const { event, respondWith } = fetchEvent(request)
      worker.listeners.fetch(event)
      expect(respondWith).not.toHaveBeenCalled()
    }
    expect(worker.fetch).not.toHaveBeenCalled()
  })

  it("passes the bytes through unchanged and keeps status and headers", async () => {
    const { countedResponse } = progress(loadWorker())
    const original = new Response(bodyStream(["export const a", " = 1;\n", "console.log(a)"]), {
      status: 200,
      statusText: "OK",
      headers: { "Content-Type": "text/javascript", "Cache-Control": "public, max-age=31536000, immutable" }
    })
    const onProgress = vi.fn()

    const counted = countedResponse(original, onProgress)

    expect(counted).not.toBe(original)
    expect(counted.status).toBe(200)
    expect(counted.statusText).toBe("OK")
    expect(counted.headers.get("content-type")).toBe("text/javascript")
    expect(counted.headers.get("cache-control")).toBe("public, max-age=31536000, immutable")
    expect(await counted.text()).toBe("export const a = 1;\nconsole.log(a)")
    expect(onProgress).toHaveBeenLastCalledWith(34, true)
    expect(onProgress.mock.calls.map(([loaded]) => loaded)).toEqual([14, 20, 34, 34])
  })

  it("returns responses it should not rewrap exactly as they came", () => {
    const { countedResponse } = progress(loadWorker())
    const onProgress = vi.fn()
    const notModified = new Response(null, { status: 304 })
    const partial = new Response("abc", { status: 206 })
    const missing = new Response("gone", { status: 404 })
    const opaque = { type: "opaque", status: 0, body: null, redirected: false } as unknown as Response
    const redirected = { type: "basic", status: 200, body: bodyStream(["x"]), redirected: true } as unknown as Response

    for (const response of [notModified, partial, missing, opaque, redirected]) {
      expect(countedResponse(response, onProgress)).toBe(response)
    }
    expect(onProgress).not.toHaveBeenCalled()
  })

  it("posts progress to the requesting client and serves the same body", async () => {
    vi.useFakeTimers({ toFake: ["Date"] })
    try {
      const page: FakeClient = { id: "page-1", postMessage: vi.fn() }
      const other: FakeClient = { id: "page-2", postMessage: vi.fn() }
      const fetchImpl = vi.fn(() => Promise.resolve(new Response(bodyStream(["0123456789", "abcdef"]), { status: 200 })))
      const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch, clients: [page, other] })
      const request = new Request(ENTRY)
      const { event, respondWith } = fetchEvent(request, { clientId: "page-1" })

      worker.listeners.fetch(event)

      expect(respondWith).toHaveBeenCalledTimes(1)
      expect(fetchImpl).toHaveBeenCalledWith(request)
      const response = (await respondWith.mock.calls[0][0]) as Response
      expect(await response.text()).toBe("0123456789abcdef")
      await vi.waitFor(() => expect(page.postMessage).toHaveBeenCalledWith(expect.objectContaining({ done: true })))

      const messages = page.postMessage.mock.calls.map(([message]) => message)
      expect(messages[0]).toEqual({ type: "syrus:startup-asset-progress", path: "/assets/spa-entry-AbC_12-x.digested.js", loaded: 0, done: false })
      expect(messages[messages.length - 1]).toEqual({ type: "syrus:startup-asset-progress", path: "/assets/spa-entry-AbC_12-x.digested.js", loaded: 16, done: true })
      expect(other.postMessage).not.toHaveBeenCalled()
    } finally {
      vi.useRealTimers()
    }
  })

  it("reports to the client a navigation is becoming, or failing that to every window", async () => {
    const page: FakeClient = { id: "new-page", postMessage: vi.fn() }
    const fetchImpl = vi.fn(() => Promise.resolve(new Response("abc", { status: 200 })))
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch, clients: [page] })

    const resulting = await progress(worker).countAssetFetch({ request: new Request(ENTRY), resultingClientId: "new-page" })
    await resulting.text()
    await vi.waitFor(() => expect(page.postMessage).toHaveBeenCalledWith(expect.objectContaining({ loaded: 3, done: true })))

    page.postMessage.mockClear()
    const unknown = await progress(worker).countAssetFetch({ request: new Request(ENTRY), clientId: "" })
    await unknown.text()
    await vi.waitFor(() => expect(page.postMessage).toHaveBeenCalledWith(expect.objectContaining({ loaded: 3, done: true })))
  })

  it("never caches what it counts", async () => {
    const open = vi.fn(() => Promise.resolve({}))
    const fetchImpl = vi.fn(() => Promise.resolve(new Response("abc", { status: 200 })))
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch, caches: { open } })

    const response = await progress(worker).countAssetFetch({ request: new Request(ENTRY) })
    await response.text()

    expect(open).not.toHaveBeenCalled()
  })

  it("falls back to the plain response when counting fails", async () => {
    const original = new Response("abc", { status: 200 })
    const fetchImpl = vi.fn(() => Promise.resolve(original))
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch })
    const OriginalTransformStream = globalThis.TransformStream
    globalThis.TransformStream = function broken() { throw new Error("no streams here") } as unknown as typeof TransformStream
    try {
      const response = await progress(worker).countAssetFetch({ request: new Request(ENTRY) })
      expect(response).toBe(original)
      expect(await response.text()).toBe("abc")
      expect(fetchImpl).toHaveBeenCalledTimes(1)
    } finally {
      globalThis.TransformStream = OriginalTransformStream
    }
  })

  it("falls back to a plain fetch when counting fails after claiming the body", async () => {
    const first = new Response("abc", { status: 200 })
    const second = new Response("abc", { status: 200 })
    const fetchImpl = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch })
    const OriginalResponse = globalThis.Response
    // Wrapping the counted stream fails after pipeThrough has locked the body.
    globalThis.Response = function broken() { throw new Error("cannot construct") } as unknown as typeof Response
    try {
      const response = await progress(worker).countAssetFetch({ request: new Request(ENTRY) })
      expect(response).toBe(second)
      expect(fetchImpl).toHaveBeenCalledTimes(2)
    } finally {
      globalThis.Response = OriginalResponse
    }
  })

  it("falls back to a plain fetch when the counting path throws before fetching", async () => {
    const plain = new Response("abc", { status: 200 })
    const fetchImpl = vi.fn().mockImplementationOnce(() => { throw new Error("boom") }).mockResolvedValueOnce(plain)
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch })
    const { event, respondWith } = fetchEvent(new Request(ENTRY))

    worker.listeners.fetch(event)

    expect(respondWith).toHaveBeenCalledTimes(1)
    expect(await respondWith.mock.calls[0][0]).toBe(plain)
  })

  it("lets a network failure reach the page as it would without the worker", async () => {
    const fetchImpl = vi.fn(() => Promise.reject(new TypeError("Failed to fetch")))
    const worker = loadWorker({ fetch: fetchImpl as unknown as typeof fetch })

    await expect(progress(worker).countAssetFetch({ request: new Request(ENTRY) })).rejects.toThrow("Failed to fetch")
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })
})
