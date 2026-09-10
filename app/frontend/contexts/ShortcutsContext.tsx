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
  layerId: number
}

type Registry = Map<string, StackEntry[]>

interface ShortcutsContextValue {
  register: (keys: string, handler: ShortcutHandler, options: ShortcutOptions, layerId?: number) => () => void
  registerLayer: (id: number) => () => void
  subscribe: (listener: () => void) => () => void
  getSnapshot: () => ShortcutRegistration[]
}

const ShortcutsContext = createContext<ShortcutsContextValue | null>(null)
const ShortcutLayerContext = createContext(0)

let nextRegistrationId = 0
let nextLayerId = 1

// Same input/textarea/contentEditable guard as AppChromeV2's sidebar search
// shortcut (SidebarSearchForm) -- shortcuts must never fire while the user is
// typing. jsdom doesn't implement `isContentEditable` (always undefined), so
// the raw attribute is checked too rather than relying on that alone.
function isTypingTarget(target: EventTarget | null): boolean {
  const element = target instanceof HTMLElement ? target : null
  if (!element) return false
  if (element.tagName === "INPUT" || element.tagName === "TEXTAREA") return true
  if (element.isContentEditable) return true
  const contentEditableAttr = element.getAttribute("contenteditable")
  return contentEditableAttr === "" || contentEditableAttr === "true"
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

function eventKeyMatchesCombo(event: KeyboardEvent, combo: ParsedCombo): boolean {
  if (event.key.toLowerCase() === combo.key) return true
  if (combo.alt && /^[a-z]$/.test(combo.key)) return event.code.toLowerCase() === `key${combo.key}`
  return false
}

function eventMatchesCombo(event: KeyboardEvent, combo: ParsedCombo): boolean {
  if (!eventKeyMatchesCombo(event, combo)) return false
  if ((event.metaKey || event.ctrlKey) !== combo.mod) return false
  if (event.altKey !== combo.alt) return false
  if (combo.shift) return event.shiftKey
  return isShiftedSymbol(combo.key) || !event.shiftKey
}

export function ShortcutsProvider({ children }: { children: ReactNode }) {
  const registryRef = useRef<Registry>(new Map())
  const layerStackRef = useRef<number[]>([])
  const listenersRef = useRef<Set<() => void>>(new Set())
  const snapshotRef = useRef<ShortcutRegistration[]>([])

  // Built once and never replaced, so `context` stays referentially stable
  // across re-renders -- otherwise every registrant's effect (keyed on
  // `context`) would tear down and re-register on every unrelated re-render
  // of the tree above it. The closures below read from the refs above at
  // call time, not at creation time, so a single build-once instance stays
  // correct for the provider's whole lifetime.
  const valueRef = useRef<ShortcutsContextValue | null>(null)
  if (!valueRef.current) {
    function activeLayerId() {
      return layerStackRef.current[layerStackRef.current.length - 1] ?? 0
    }

    function activeRegistrations() {
      const layerId = activeLayerId()
      return Array.from(registryRef.current.values())
        .map((stack) => {
          for (let index = stack.length - 1; index >= 0; index -= 1) {
            if (stack[index].layerId === layerId) return stack[index].registration
          }
          return null
        })
        .filter((registration): registration is ShortcutRegistration => registration != null)
    }

    function notify() {
      snapshotRef.current = activeRegistrations()
      listenersRef.current.forEach((listener) => listener())
    }

    function register(keys: string, handler: ShortcutHandler, options: ShortcutOptions, layerId = 0) {
      const normalizedKeys = keys.toLowerCase()
      const registration: ShortcutRegistration = {
        id: nextRegistrationId++,
        keys: normalizedKeys,
        description: options.description,
        group: options.group,
        groupOrder: options.groupOrder ?? 0
      }

      const stack = registryRef.current.get(normalizedKeys) ?? []
      stack.push({ registration, handler, layerId })
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

    valueRef.current = {
      register,
      registerLayer(id) {
        layerStackRef.current.push(id)
        notify()

        return () => {
          const index = layerStackRef.current.lastIndexOf(id)
          if (index !== -1) layerStackRef.current.splice(index, 1)
          notify()
        }
      },
      subscribe(listener) {
        listenersRef.current.add(listener)
        return () => listenersRef.current.delete(listener)
      },
      getSnapshot() {
        return snapshotRef.current
      }
    }
  }

  useEffect(() => {
    function onKeyDown(event: globalThis.KeyboardEvent) {
      if (isTypingTarget(event.target)) return

      for (const stack of registryRef.current.values()) {
        const layerId = layerStackRef.current[layerStackRef.current.length - 1] ?? 0
        const active = [...stack].reverse().find((entry) => entry.layerId === layerId)
        if (active && eventMatchesCombo(event, parseCombo(active.registration.keys))) {
          event.preventDefault()
          active.handler(event)
          return
        }
      }
    }

    window.addEventListener("keydown", onKeyDown)
    return () => window.removeEventListener("keydown", onKeyDown)
  }, [])

  return <ShortcutsContext.Provider value={valueRef.current}>{children}</ShortcutsContext.Provider>
}

function useShortcutsContext(): ShortcutsContextValue {
  const context = useContext(ShortcutsContext)
  if (!context) throw new Error("useShortcut must be used within a ShortcutsProvider")
  return context
}

function useOptionalShortcutsContext(): ShortcutsContextValue | null {
  return useContext(ShortcutsContext)
}

// Registers a keyboard shortcut for as long as the calling component is
// mounted. Overlapping registrations for the same combo shadow LIFO by mount
// order (e.g. a modal opened over a page wins over the page's shortcut);
// unmounting restores whichever registration was active before it.
export function useShortcut(keys: string, handler: ShortcutHandler, options: ShortcutOptions): void {
  const context = useShortcutsContext()
  const layerId = useContext(ShortcutLayerContext)
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    return context.register(keys, (event) => handlerRef.current(event), options, layerId)
  }, [context, keys, layerId, options.description, options.group, options.groupOrder])
}

// Like useShortcut, but quietly does nothing when a component is rendered
// outside the app shell's provider (common in focused component tests).
export function useOptionalShortcut(keys: string, handler: ShortcutHandler, options: ShortcutOptions): void {
  const context = useOptionalShortcutsContext()
  const layerId = useContext(ShortcutLayerContext)
  const handlerRef = useRef(handler)
  handlerRef.current = handler

  useEffect(() => {
    if (!context) return
    return context.register(keys, (event) => handlerRef.current(event), options, layerId)
  }, [context, keys, layerId, options.description, options.group, options.groupOrder])
}

// Creates a modal/tool-local shortcut layer. While mounted, shortcuts from
// lower layers are neither dispatched nor listed in the help modal unless
// this layer declares them again.
export function ShortcutLayer({ children }: { children: ReactNode }) {
  const context = useOptionalShortcutsContext()
  const layerIdRef = useRef<number | null>(null)
  if (layerIdRef.current == null) layerIdRef.current = nextLayerId++

  useEffect(() => {
    if (!context) return
    return context.registerLayer(layerIdRef.current!)
  }, [context])

  return <ShortcutLayerContext.Provider value={layerIdRef.current}>{children}</ShortcutLayerContext.Provider>
}

// Live snapshot of every currently-active (i.e. not shadowed) shortcut
// registration, for the help modal to render.
export function useActiveShortcuts(): ShortcutRegistration[] {
  const context = useShortcutsContext()
  return useSyncExternalStore(context.subscribe, context.getSnapshot, context.getSnapshot)
}
