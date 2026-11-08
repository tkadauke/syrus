import { vi } from "vitest"

// Shared mock state for App integration suites. Each suite registers the module
// mocks with `vi.mock(..., () => import(...))` factories exported here, and
// `installAppTestLifecycle` (./lifecycle) resets this state around every test.

export const actionCable = {
  createSubscription: vi.fn(() => ({ unsubscribe: vi.fn() }))
}

export const excalidrawMock = {
  throwOnRender: false,
  addFiles: vi.fn(),
  lastInitialData: null as { appState?: Record<string, unknown>; elements?: unknown[]; files?: Record<string, Record<string, unknown>> } | null,
  onChange: null as ((elements: unknown[], appState: Record<string, unknown>, files: Record<string, Record<string, unknown>>) => void) | null,
  updateScene: vi.fn()
}

export const html2canvasMock = vi.fn(async () => ({
  toBlob(callback: (blob: Blob | null) => void) {
    callback(new Blob(["screenshot"], { type: "image/png" }))
  }
}))

export function actionCableModule() {
  return {
    createConsumer: () => ({
      subscriptions: {
        create: actionCable.createSubscription
      }
    })
  }
}

export function excalidrawModule() {
  return {
    Excalidraw: ({
      excalidrawAPI,
      initialData,
      onChange
    }: {
      excalidrawAPI?: (api: { addFiles: typeof excalidrawMock.addFiles; updateScene: typeof excalidrawMock.updateScene }) => void
      initialData?: { appState?: Record<string, unknown>; elements?: unknown[]; files?: Record<string, Record<string, unknown>> }
      onChange?: (elements: unknown[], appState: Record<string, unknown>, files: Record<string, Record<string, unknown>>) => void
    }) => {
      if (excalidrawMock.throwOnRender) throw new Error("Canvas crashed")

      excalidrawMock.lastInitialData = initialData || null
      excalidrawMock.onChange = onChange || null
      excalidrawAPI?.({ addFiles: excalidrawMock.addFiles, updateScene: excalidrawMock.updateScene })

      return (
        <button
          onClick={() =>
            onChange?.(
              [...(initialData?.elements || []), { id: "shape-react", type: "image", fileId: "file-react", version: 1 }],
              { ...(initialData?.appState || {}), viewBackgroundColor: "#ffffff", selectedElementIds: { "shape-react": true } },
              {
                ...(initialData?.files || {}),
                "file-react": {
                  id: "file-react",
                  dataURL: "data:image/png;base64,abc",
                  mimeType: "image/png",
                  created: 1
                }
              }
            )
          }
          type="button"
        >
          Draw on whiteboard
        </button>
      )
    }
  }
}

export function html2canvasModule() {
  return { default: html2canvasMock }
}
