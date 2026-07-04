import "../i18n"
import "@testing-library/jest-dom/vitest"
import { cleanup } from "@testing-library/react"
import { afterEach, vi } from "vitest"
import "../i18n"

function ensureLocalStorage() {
  if (typeof window === "undefined") return

  try {
    if (window.localStorage) return
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

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
  vi.restoreAllMocks()
})
