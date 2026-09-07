import { createContext, useContext, useEffect, useRef, useSyncExternalStore, type ReactNode } from "react"

export interface ShortcutOptions {
  description: string
  group: string
  // Controls ordering of groups in the help modal; lower sorts first. Groups
  // sharing an order (the default) fall back to alphabetical.
  groupOrder?: number
}

export interface ShortcutRegistration extends ShortcutOptions {
  id: number
  keys: string
}

type ShortcutHandler = (event: KeyboardEvent) => void

interface StackEntry {
  registration: ShortcutRegistration
  handler: ShortcutHandler
}

type Registry = Map<string, StackEntry[]>

interface ShortcutsContextValue {
  register: (keys: string, handler: ShortcutHandler, options: ShortcutOptions) => () => void
  subscribe: (listener: () => void) => () => void
  getSnapshot: () => ShortcutRegistration[]
}

const ShortcutsContext = createContext<ShortcutsContextValue | null>(null)

let nextRegistrationId = 0

// Same input/textarea/contentEditable guard as AppChromeV2's sidebar search
// shortcut (SidebarSearchForm) -- shortcuts must never fire while the user is
// typing.
function isTypingTarget(target: EventTarget | null): boolean {
  const element = target instanceof HTMLElement ? target : null
  return element?.tagName === "INPUT" || element?.tagName === "TEXTAREA" || element?.isContentEditable === true
}

interface ParsedCombo {
  mod: boolean
  alt: boolean
  shift: boolean
  key: string
}

function parseCombo(combo: string): ParsedCombo {
  const parts = combo.toLowerCase().split("+").map((part) => part.trim()).filter(Boolean)
  return {
    mod: parts.includes("mod"),
    alt: parts.includes("alt"),
    shift: parts.includes("shift"),
    key: parts[parts.length - 1] ?? ""
  }
}

// A bare symbol like "?" is only reachable via Shift on most layouts, so the
// browser-reported event.key already encodes it -- don't also require an
// explicit "shift+" in the combo for those.
function isShiftedSymbol(key: string): boolean {
  return key.length === 1 && !/[a-z0-9]/.test(key)
}

function eventMatchesCombo(event: KeyboardEvent, combo: ParsedCombo): boolean {
  if (event.key.toLowerCase() !== combo.key) return false
  if ((event.metaKey || event.ctrlKey) !== combo.mod) return false
  if (event.altKey !== combo.alt) return false
  if (combo.shift) return event.shiftKey
  return isShiftedSymbol(combo.key) || !event.shiftKey
}

export function ShortcutsProvider({ children }: { children: ReactNode }) {
  const registryRef = useRef<Registry>(new Map())
  const listenersRef = useRef<Set<() => void>>(new Set())
  const snapshotRef = useRef<ShortcutRegistration[]>([])

  function notify() {
    snapshotRef.current = Array.from(registryRef.current.values())
      .map((stack) => stack[stack.length - 1]?.registration)
      .filter((registration): registration is ShortcutRegistration => registration != null)
    listenersRef.current.forEach((listener) => listener())
  }

  function register(keys: string, handler: ShortcutHandler, options: ShortcutOptions) {
    const normalizedKeys = keys.toLowerCase()
    const registration: ShortcutRegistration = {
      id: nextRegistrationId++,
      keys: normalizedKeys,
      description: options.description,
      group: options.group,
      groupOrder: options.groupOrder ?? 0
    }

    const stack = registryRef.current.get(normalizedKeys) ?? []
    stack.push({ registration, handler })
    registryRef.current.set(normalizedKeys, stack)
    notify()

    return () => {
      const currentStack = registryRef.current.get(normalizedKeys)
      if (!currentStack) return

      const index = currentStack.findIndex((entry) => entry.registration.id === registration.id)
      if (index === -1) return

      currentStack.splice(index, 1)
      if (currentStack.length === 0) registryRef.current.delete(normalizedKeys)
      notify()
    }
  }

  useEffect(() => {
    function onKeyDown(event: globalThis.KeyboardEvent) {
      if (isTypingTarget(event.target)) return

      for (const stack of registryRef.current.values()) {
        const active = stack[stack.length - 1]
        if (active && eventMatchesCombo(event, parseCombo(active.registration.keys))) {
          active.handler(event)
          return
        }
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [])

  const value: ShortcutsContextValue = {
    register,
    subscribe(listener) {
      listenersRef.current.add(listener)
      return () => listenersRef.current.delete(listener)
    },
    getSnapshot() {
      return snapshotRef.current
    }
  }

  return <ShortcutsContext.Provider value={value}>{children}</ShortcutsContext.Provider>
}

function useShortcutsContext(): ShortcutsContextValue {
  const context = useContext(ShortcutsContext)
  if (!context) throw new Error("useShortcut must be used within a ShortcutsProvider")
  return context
}

// Registers a keyboard shortcut for as long as the calling component is
// mounted. Overlapping registrations for the same combo shadow LIFO by mount
// order (e.g. a modal opened over a page wins over the page's shortcut);
// unmounting restores whichever registration was active before it.
export function useShortcut(keys: string, handler: ShortcutHandler, options: ShortcutOptions): void {
  const context = useShortcutsContext()
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    return context.register(keys, (event) => handlerRef.current(event), options)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [context, keys, options.description, options.group, options.groupOrder])
}

// Live snapshot of every currently-active (i.e. not shadowed) shortcut
// registration, for the help modal to render.
export function useActiveShortcuts(): ShortcutRegistration[] {
  const context = useShortcutsContext()
  return useSyncExternalStore(context.subscribe, context.getSnapshot, context.getSnapshot)
}
