import "../i18n"
import "@testing-library/jest-dom/vitest"
import { resetApiClientStateForTests } from "../api/clientTestState"
import { cleanup, configure } from "@testing-library/react"
import { afterEach, vi } from "vitest"
import { _clearRecentApiRequestsForTest } from "../api/client"
import "../i18n"

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

function installBootstrapSlugRegistry() {
  const existing = document.getElementById("syrus-bootstrap-data")
  if (existing) existing.remove()

  const element = document.createElement("script")
  element.id = "syrus-bootstrap-data"
  element.type = "application/json"
  element.textContent = JSON.stringify({
    slug_refs: {
      types: [
        {
          prefix: "JOB",
          type: "job",
          display_label: "Job",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/jobs/JOB-:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "EPIC",
          type: "epic",
          display_label: "Epic",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/epics/EPIC-:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "CHAT",
          type: "chat",
          display_label: "Chat",
          copyable: true,
          linkable: false,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: null,
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        },
        {
          prefix: "DOC",
          type: "design_doc",
          display_label: "Design Doc",
          copyable: true,
          linkable: true,
          preview_available: true,
          linkifies_generated_text: true,
          href_template: "/design_docs/:id",
          mobile_interaction_hints: { tap: "open", long_press: "copy" }
        }
      ]
    }
  })
  document.head.appendChild(element)
}

installBootstrapSlugRegistry()

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
  installBootstrapSlugRegistry()
  vi.clearAllMocks()
  vi.restoreAllMocks()
})
