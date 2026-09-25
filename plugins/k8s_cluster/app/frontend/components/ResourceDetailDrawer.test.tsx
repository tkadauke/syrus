import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { toYaml } from "../lib/toYaml"
import { ResourceDetailDrawer, type ResourceDetailSelection } from "./ResourceDetailDrawer"

const GENERATED_AT = "2026-01-01T00:00:00Z"

const SELECTION: ResourceDetailSelection = {
  kind: "pod",
  kindLabel: "Pods",
  name: "web-1",
  namespace: "default",
  fields: [
    { label: "Namespace", value: "default" },
    { label: "Status", value: "Running" }
  ]
}

const POD_OBJECT = {
  apiVersion: "v1",
  kind: "Pod",
  metadata: { name: "web-1", namespace: "default" },
  spec: { nodeName: "node-1", containers: [{ name: "app", image: "web:1.0" }] },
  status: { phase: "Running", podIP: "10.0.0.5" }
}

function renderDrawer(selection: ResourceDetailSelection | null, onClose: () => void = vi.fn()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <ResourceDetailDrawer clusterId={1} onClose={onClose} selection={selection} />
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("toYaml", () => {
  it("renders scalars, null, and empty collections", () => {
    expect(toYaml(null)).toBe("null")
    expect(toYaml(true)).toBe("true")
    expect(toYaml(3)).toBe("3")
    expect(toYaml("Running")).toBe("Running")
    expect(toYaml([])).toBe("[]")
    expect(toYaml({})).toBe("{}")
  })

  it("renders nested objects and arrays with two-space indent", () => {
    expect(toYaml({ metadata: { name: "web-1", labels: { app: "web" } }, containers: [{ name: "app" }, { name: "sidecar" }] })).toBe(
      "metadata:\n  name: web-1\n  labels:\n    app: web\ncontainers:\n  - \n    name: app\n  - \n    name: sidecar"
    )
  })

  it("quotes strings that YAML would otherwise misread", () => {
    expect(toYaml("")).toBe('""')
    expect(toYaml("true")).toBe('"true"')
    expect(toYaml("123")).toBe('"123"')
    expect(toYaml("a: b")).toBe('"a: b"')
    expect(toYaml(" leading")).toBe('" leading"')
    expect(toYaml('say "hi"')).toBe('"say \\"hi\\""')
    expect(toYaml("line one\nline two")).toBe('"line one\\nline two"')
  })

  it("quotes keys with special characters", () => {
    expect(toYaml({ "app.kubernetes.io/name": "web" })).toBe('"app.kubernetes.io/name": web')
  })
})

describe("ResourceDetailDrawer", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders nothing without a selection and issues no request", () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockRejectedValue(new Error("should not fetch"))
    renderDrawer(null)

    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("shows key fields plus a read-only YAML view of the describe object", async () => {
    const calls: string[] = []
    vi.spyOn(window, "fetch").mockImplementation(((input: RequestInfo | URL) => {
      calls.push(String(input))
      return Promise.resolve(jsonResponse({ available: true, generated_at: GENERATED_AT, pod: POD_OBJECT }))
    }) as typeof window.fetch)
    renderDrawer(SELECTION)

    expect(await screen.findByRole("dialog", { name: "Pods default/web-1" })).toBeInTheDocument()
    expect(calls).toHaveLength(1)
    expect(calls[0]).toContain("/pods?")
    expect(calls[0]).toContain("name=web-1")
    expect(calls[0]).toContain("namespace=default")
    expect(screen.getByText("Namespace")).toBeInTheDocument()
    expect(screen.getByText("Running")).toBeInTheDocument()
    expect(screen.getByText("Read-only — values cannot be edited here.")).toBeInTheDocument()
    expect(await screen.findByText(/kind: Pod/)).toBeInTheDocument()
    expect(await screen.findByText(/nodeName: node-1/)).toBeInTheDocument()
  })

  it("shows a loading state while the describe fetch is in flight", async () => {
    // Resolve after asserting: the shared API client dedupes in-flight reads
    // by path in a module-level map, so a fetch that never settles would
    // poison the same path for every later test in this file.
    let resolveFetch!: (response: Response) => void
    vi.spyOn(window, "fetch").mockImplementation(
      (() =>
        new Promise<Response>((resolve) => {
          resolveFetch = resolve
        })) as typeof window.fetch
    )
    const { unmount } = renderDrawer(SELECTION)

    expect(await screen.findByText("Loading details…")).toBeInTheDocument()
    resolveFetch(jsonResponse({ available: true, generated_at: GENERATED_AT, pod: POD_OBJECT }))
    unmount()
  })

  it("shows an error when the describe fetch fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation((() => Promise.resolve(jsonResponse({ error: { message: "boom-describe" } }, 502))) as typeof window.fetch)
    renderDrawer(SELECTION)

    expect(await screen.findByText("boom-describe")).toBeInTheDocument()
  })

  it("closes via the close button, the backdrop, and Escape", async () => {
    vi.spyOn(window, "fetch").mockImplementation((() =>
      Promise.resolve(jsonResponse({ available: true, generated_at: GENERATED_AT, pod: POD_OBJECT }))) as typeof window.fetch)
    const onClose = vi.fn()
    renderDrawer(SELECTION, onClose)

    const dialog = await screen.findByRole("dialog")
    fireEvent.click(screen.getByRole("button", { name: "Close details" }))
    expect(onClose).toHaveBeenCalledTimes(1)

    fireEvent.click(dialog.parentElement!)
    expect(onClose).toHaveBeenCalledTimes(2)

    fireEvent.keyDown(document, { key: "Escape" })
    expect(onClose).toHaveBeenCalledTimes(3)
  })
})
