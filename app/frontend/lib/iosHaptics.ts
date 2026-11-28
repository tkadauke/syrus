// Adapter for the iOS shell's narrow haptics bridge. The Swift side
// (ios/Syrus/Web/HapticsBridge.swift) registers a `syrusHaptics` script
// message handler and accepts only the two payload shapes built here. In an
// ordinary browser (or Electron) every function is a silent no-op.

export type ImpactStyle = "light" | "medium" | "heavy"
export type HapticRequest = { v: 1; kind: "selection" } | { v: 1; kind: "impact"; style: ImpactStyle }

export const HAPTICS_HANDLER_NAME = "syrusHaptics"
// Users can opt out per device: localStorage["syrus.haptics"] = "off".
export const HAPTICS_PREFERENCE_KEY = "syrus.haptics"

type MessageHandler = { postMessage: (message: unknown) => void }

function handler(): MessageHandler | null {
  if (typeof window === "undefined" || typeof navigator === "undefined") return null
  if (!/\bSyrusiOS\//.test(navigator.userAgent)) return null
  const candidate = (window as unknown as { webkit?: { messageHandlers?: Record<string, MessageHandler | undefined> } }).webkit?.messageHandlers?.[
    HAPTICS_HANDLER_NAME
  ]
  return candidate && typeof candidate.postMessage === "function" ? candidate : null
}

export function iosHapticsAvailable(): boolean {
  return handler() !== null
}

function hapticsAllowed(): boolean {
  try {
    if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return false
    if (window.localStorage.getItem(HAPTICS_PREFERENCE_KEY) === "off") return false
  } catch {
    // handled-error-expected: storage may be unavailable; fall back to enabled.
  }
  return true
}

function send(request: HapticRequest): boolean {
  const target = handler()
  if (!target || !hapticsAllowed()) return false
  try {
    target.postMessage(request)
    return true
  } catch {
    // handled-error-expected: haptics are best-effort and must never break the UI.
    return false
  }
}

export const haptics = {
  selection: () => send({ v: 1, kind: "selection" }),
  impact: (style: ImpactStyle = "medium") => send({ v: 1, kind: "impact", style })
}
