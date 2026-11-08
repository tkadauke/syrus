import { vi } from "vitest"
import { registerAppTestCleanup } from "./lifecycle"

function replaceProperty(target: object, key: string, descriptor: PropertyDescriptor) {
  const original = Object.getOwnPropertyDescriptor(target, key)
  Object.defineProperty(target, key, descriptor)
  registerAppTestCleanup(() => {
    if (original) Object.defineProperty(target, key, original)
    else Reflect.deleteProperty(target, key)
  })
}

// Replaces HTMLElement.prototype.scrollIntoView until the current test ends.
export function stubScrollIntoView() {
  const scrollIntoView = vi.fn()
  replaceProperty(window.HTMLElement.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView })
  return scrollIntoView
}

// Replaces navigator.clipboard with the given writeText until the current test ends.
export function stubClipboardWriteText(writeText: (text: string) => unknown) {
  replaceProperty(navigator, "clipboard", { configurable: true, value: { writeText } })
}
