import i18n, { i18nReady, loadPluginLocales, supportedLocales } from "../i18n"
import "@testing-library/jest-dom/vitest"
import { resetApiClientStateForTests } from "../api/clientTestState"
import { cleanup, configure } from "@testing-library/react"
import { afterEach, vi } from "vitest"
import { _clearRecentApiRequestsForTest } from "../api/client"

// jsdom's Blob lacks stream(), which @shikijs/engine-oniguruma's inlined wasm
// loader calls (Blob -> stream -> DecompressionStream). Provide it from the
// Blob's bytes so the real highlighter engine initializes under test.
if (typeof Blob.prototype.stream !== "function") {
  Blob.prototype.stream = function stream(this: Blob): ReadableStream<Uint8Array<ArrayBuffer>> {
    const blob = this
    return new ReadableStream<Uint8Array<ArrayBuffer>>({
      async start(controller) {
        const buffer = await new Promise<ArrayBuffer>((resolve, reject) => {
          const reader = new FileReader()
          reader.onload = () => resolve(reader.result as ArrayBuffer)
          reader.onerror = () => reject(reader.error)
          reader.readAsArrayBuffer(blob)
        })
        controller.enqueue(new Uint8Array(buffer))
        controller.close()
      }
    })
  }
}

await i18nReady
// Keep direct fixed-locale assertions deterministic. Production-shaped lazy
// boundary specs explicitly remove the resource bundle they exercise.
await i18n.loadLanguages([...supportedLocales])

// Plugin card specs import their modules directly rather than through a real
// route/tool-card boundary. Prepare their active-language resources here; the
// production-shaped registry specs remove a bundle before rendering to prove
// that the application boundary restores it.
const pluginLocaleModules = import.meta.glob("../../../plugins/*/app/frontend/i18n/locales/*/*.json")
const pluginNames = new Set(
  Object.keys(pluginLocaleModules).flatMap((path) => {
    const match = path.match(/\/plugins\/([^/]+)\/app\/frontend\/i18n\/locales\//)
    return match ? [match[1]] : []
  })
)
await Promise.all([...pluginNames].map(loadPluginLocales))

// Components that use the shared Action Cable consumer must not open real
// sockets from jsdom. Individual cable-focused specs can still provide their
// own module mock or inject a consumer directly.
vi.mock("@rails/actioncable", () => ({
  createConsumer: () => ({
    subscriptions: {
      create: () => ({
        perform: () => undefined,
        unsubscribe: () => undefined
      })
    }
  })
}))

// Coverage instrumentation adds ~40% overhead. Raise the default 1000ms
// asyncUtilTimeout so findBy* queries don't expire before slow components
// finish rendering their async data under instrumented builds.
configure({ asyncUtilTimeout: 5000 })

function ensureLocalStorage() {
  if (typeof window === "undefined") return

  try {
    // Present AND functional: Node >= 23 ships a global localStorage that,
    // without --localstorage-file, is an object whose methods are all
    // undefined — and it shadows jsdom's working Storage in the vitest
    // global. Presence alone is not enough; probe a method.
    if (window.localStorage && typeof window.localStorage.setItem === "function") return
  } catch {
    // Fall through and install a test double for environments with disabled storage.
  }

  let store: Record<string, string> = {}
  const storage: Storage = {
    get length() {
      return Object.keys(store).length
    },
    clear() {
      store = {}
    },
    getItem(key: string) {
      return Object.prototype.hasOwnProperty.call(store, key) ? store[key] : null
    },
    key(index: number) {
      return Object.keys(store)[index] ?? null
    },
    removeItem(key: string) {
      delete store[key]
    },
    setItem(key: string, value: string) {
      store[key] = String(value)
    }
  }

  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: storage
  })
}

ensureLocalStorage()

// jsdom does not implement scrollIntoView; provide a noop so tests that
// indirectly open scrollable lists (e.g. the slash command palette) don't
// throw. Individual tests that need to assert scroll behavior can override
// this with their own vi.fn() via Object.defineProperty(..., configurable: true).
Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
  configurable: true,
  writable: true,
  value: () => {}
})

afterEach(() => {
  resetApiClientStateForTests()
  cleanup()
  _clearRecentApiRequestsForTest()
  vi.clearAllMocks()
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
})
