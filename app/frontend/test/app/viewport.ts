import { vi } from "vitest"
import { clipboardMockState } from "./lifecycle"

export function mockMediaQuery(matches: boolean) {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })

  return () => {
    if (original) {
      Object.defineProperty(window, "matchMedia", original)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  }
}

export function mockViewportWidth(width: number) {
  const original = Object.getOwnPropertyDescriptor(window, "matchMedia")

  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: matchesViewportWidth(query, width),
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })

  return () => {
    if (original) {
      Object.defineProperty(window, "matchMedia", original)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  }
}

export function matchesViewportWidth(query: string, width: number) {
  const minMatch = query.match(/min-width:\s*(\d+)px/)
  if (minMatch) return width >= Number(minMatch[1])

  const maxMatch = query.match(/max-width:\s*(\d+)px/)
  if (maxMatch) return width <= Number(maxMatch[1])

  return false
}

export function setViewportWidth(width: number) {
  const originalWidth = window.innerWidth
  Object.defineProperty(window, "innerWidth", { configurable: true, writable: true, value: width })
  window.dispatchEvent(new Event("resize"))

  return () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, writable: true, value: originalWidth })
    window.dispatchEvent(new Event("resize"))
  }
}

export function setViewportHeight(height: number) {
  const originalHeight = window.innerHeight
  Object.defineProperty(window, "innerHeight", { configurable: true, writable: true, value: height })

  return () => {
    Object.defineProperty(window, "innerHeight", { configurable: true, writable: true, value: originalHeight })
  }
}

export function mockClipboardWrite() {
  const originalClipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard")
  const writeText = vi.fn().mockImplementation(async () => undefined)

  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: { writeText }
  })

  clipboardMockState.restore = () => {
    if (originalClipboard) {
      Object.defineProperty(navigator, "clipboard", originalClipboard)
    } else {
      Reflect.deleteProperty(navigator, "clipboard")
    }
  }

  return writeText
}

export function stubVisualViewport(initialMetrics: number | { height: number; offsetLeft?: number; offsetTop?: number; scale?: number; width?: number }) {
  const original = Object.getOwnPropertyDescriptor(window, "visualViewport")
  const listeners = new Map<string, Set<EventListenerOrEventListenerObject>>()
  let metrics =
    typeof initialMetrics === "number"
      ? { height: initialMetrics, offsetLeft: 0, offsetTop: 0, scale: 1, width: window.innerWidth }
      : { offsetLeft: 0, offsetTop: 0, scale: 1, width: window.innerWidth, ...initialMetrics }
  const viewport = {
    get height() {
      return metrics.height
    },
    get offsetLeft() {
      return metrics.offsetLeft
    },
    get offsetTop() {
      return metrics.offsetTop
    },
    get scale() {
      return metrics.scale
    },
    get width() {
      return metrics.width
    },
    addEventListener: vi.fn((type: string, listener: EventListenerOrEventListenerObject) => {
      const typeListeners = listeners.get(type) || new Set<EventListenerOrEventListenerObject>()
      typeListeners.add(listener)
      listeners.set(type, typeListeners)
    }),
    removeEventListener: vi.fn((type: string, listener: EventListenerOrEventListenerObject) => {
      listeners.get(type)?.delete(listener)
    })
  }

  Object.defineProperty(window, "visualViewport", {
    configurable: true,
    value: viewport
  })

  return {
    setHeight(nextHeight: number) {
      metrics = { ...metrics, height: nextHeight }
    },
    setMetrics(nextMetrics: Partial<typeof metrics>) {
      metrics = { ...metrics, ...nextMetrics }
    },
    dispatch(type: string) {
      listeners.get(type)?.forEach((listener) => {
        if (typeof listener === "function") {
          listener(new Event(type))
        } else {
          listener.handleEvent(new Event(type))
        }
      })
    },
    restore() {
      if (original) {
        Object.defineProperty(window, "visualViewport", original)
      } else {
        Reflect.deleteProperty(window, "visualViewport")
      }
    }
  }
}

export function setScrollMetrics(element: HTMLElement, metrics: { scrollHeight: number; clientHeight: number; scrollTop: number }) {
  Object.defineProperty(element, "scrollHeight", { configurable: true, value: metrics.scrollHeight })
  Object.defineProperty(element, "clientHeight", { configurable: true, value: metrics.clientHeight })
  Object.defineProperty(element, "scrollTop", { configurable: true, writable: true, value: metrics.scrollTop })
}

export function stubChatStreamSize(metrics: { scrollHeight: number; clientHeight: number }) {
  const scrollHeightDescriptor = Object.getOwnPropertyDescriptor(window.HTMLElement.prototype, "scrollHeight")
  const clientHeightDescriptor = Object.getOwnPropertyDescriptor(window.HTMLElement.prototype, "clientHeight")

  Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", {
    configurable: true,
    get() {
      return this instanceof HTMLElement && this.dataset.testid === "chat-message-stream" ? metrics.scrollHeight : 0
    }
  })
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get() {
      return this instanceof HTMLElement && this.dataset.testid === "chat-message-stream" ? metrics.clientHeight : 0
    }
  })

  return () => {
    if (scrollHeightDescriptor) {
      Object.defineProperty(window.HTMLElement.prototype, "scrollHeight", scrollHeightDescriptor)
    } else {
      Reflect.deleteProperty(window.HTMLElement.prototype, "scrollHeight")
    }
    if (clientHeightDescriptor) {
      Object.defineProperty(window.HTMLElement.prototype, "clientHeight", clientHeightDescriptor)
    } else {
      Reflect.deleteProperty(window.HTMLElement.prototype, "clientHeight")
    }
  }
}
