// Whiteboard scene helpers extracted from Chat.tsx.
//
// Pure functions (no React/JSX) that read the chat payload's whiteboard
// state, clone scenes, re-key elements to fresh ids, compute a change
// signature, and sanitize Excalidraw appState/files. Extracted so the
// WhiteboardPanel/MediaGallery components no longer couple to file-local
// helpers in the 6k-line Chat.tsx.
import type { ExcalidrawImperativeAPI } from "@excalidraw/excalidraw/types"
import type { ExcalidrawElement } from "@excalidraw/excalidraw/element/types"
import type { ChatPayload, ChatWhiteboardElement, ChatWhiteboardScene } from "../../api/chats"

type ExcalidrawApi = Pick<ExcalidrawImperativeAPI, "addFiles" | "updateScene">

export function whiteboardElements(payload: ChatPayload): ChatWhiteboardElement[] {
  return whiteboardScene(payload).elements
}

export function whiteboardScene(payload: ChatPayload): ChatWhiteboardScene {
  return normalizeWhiteboardScene(payload.whiteboard)
}

export function normalizeWhiteboardScene(scene: Partial<ChatWhiteboardScene> | null | undefined): ChatWhiteboardScene {
  return {
    elements: Array.isArray(scene?.elements) ? scene.elements : [],
    appState: cleanWhiteboardAppState(scene?.appState),
    files: isPlainObject(scene?.files) ? (scene.files as ChatWhiteboardScene["files"]) : {}
  }
}

export function cloneWhiteboardScene(scene: ChatWhiteboardScene): ChatWhiteboardScene {
  return {
    elements: JSON.parse(JSON.stringify(scene.elements)) as ChatWhiteboardElement[],
    appState: cleanWhiteboardAppState(scene.appState),
    files: cleanWhiteboardFiles(scene.files)
  }
}

export function withFreshElementIds(elements: ChatWhiteboardElement[]) {
  const copied = JSON.parse(JSON.stringify(elements)) as ChatWhiteboardElement[]
  const idMap = new Map<string, string>()

  copied.forEach((element) => {
    const id = typeof element.id === "string" ? element.id : null
    if (id) idMap.set(id, newElementId())
  })

  return copied.map((element) => replaceElementIdReferences(element, idMap) as ChatWhiteboardElement)
}

export function replaceElementIdReferences(value: unknown, idMap: Map<string, string>): unknown {
  if (typeof value === "string") return idMap.get(value) || value
  if (Array.isArray(value)) return value.map((item) => replaceElementIdReferences(item, idMap))
  if (!isPlainObject(value)) return value

  return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, replaceElementIdReferences(child, idMap)]))
}

export function newElementId() {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) return crypto.randomUUID().replace(/-/g, "")

  return `snapshot${Date.now().toString(36)}${Math.random().toString(36).slice(2)}`
}

export function signatureForScene(scene: ChatWhiteboardScene) {
  return JSON.stringify(scene)
}

export const VALID_EXCALIDRAW_TYPES = new Set([
  "selection",
  "rectangle",
  "diamond",
  "ellipse",
  "embeddable",
  "iframe",
  "image",
  "frame",
  "magicframe",
  "text",
  "line",
  "arrow",
  "freedraw"
])

export function asExcalidrawElements(elements: readonly ChatWhiteboardElement[]) {
  return elements.filter((el) => VALID_EXCALIDRAW_TYPES.has((el as { type?: string }).type ?? "")) as unknown as readonly ExcalidrawElement[]
}

export function asExcalidrawFiles(files: ChatWhiteboardScene["files"]) {
  return Object.values(files) as Parameters<ExcalidrawApi["addFiles"]>[0]
}

export function cleanWhiteboardAppState(value: unknown): ChatWhiteboardScene["appState"] {
  const appState = safeJsonObject(value)
  delete appState.activeTool
  delete appState.selectedElementIds
  delete appState.selectedGroupIds
  delete appState.collaborators
  delete appState.editingElement
  delete appState.resizingElement
  delete appState.draggingElement
  delete appState.multiElement
  delete appState.suggestedBindings
  delete appState.startBoundElement
  return appState
}

export function cleanWhiteboardFiles(value: unknown): ChatWhiteboardScene["files"] {
  const files = safeJsonObject(value)
  return Object.fromEntries(Object.entries(files).filter(([, file]) => isPlainObject(file))) as ChatWhiteboardScene["files"]
}

export function safeJsonObject(value: unknown): Record<string, unknown> {
  if (!isPlainObject(value)) return {}

  try {
    const parsed = JSON.parse(JSON.stringify(value)) as unknown
    return isPlainObject(parsed) ? parsed : {}
  } catch {
    return {}
  }
}

export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}
