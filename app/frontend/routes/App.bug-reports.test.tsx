import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { html2canvasMock } from "../test/app/appMocks"
import { bootstrapPayload } from "../test/app/bootstrap"
import { chatPayload } from "../test/app/chatPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App bug reports", () => {
  installAppTestLifecycle()

  it("submits bug reports from the shared app chrome", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Bug report queued.", job_id: 44 }), { status: 201, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click((await screen.findAllByRole("button", { name: "Report a bug" }))[0])
      const dialog = await screen.findByRole("dialog", { name: "Report a bug" })
      expect(dialog).toBeInTheDocument()
      expect(dialog.parentElement).toHaveAttribute("data-html2canvas-ignore")
      expect(screen.getByLabelText("Title")).toHaveValue("Dashboard bug")
      expect(html2canvasMock).toHaveBeenCalledTimes(1)
      expect(screen.getByRole("radio", { name: "Viewport" })).toBeChecked()
      expect(screen.getByRole("radio", { name: "Full page" })).toBeInTheDocument()
      expect(screen.getByRole("radio", { name: "No screenshot" })).toBeInTheDocument()
      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      await waitFor(() => expect(html2canvasMock).toHaveBeenCalledTimes(2))
      expect(html2canvasMock).toHaveBeenLastCalledWith(
        document.body,
        expect.objectContaining({
          x: 0,
          y: 0,
          scrollX: 0,
          scrollY: 0,
          scale: 1
        })
      )
      fireEvent.change(screen.getByLabelText("Description"), { target: { value: "The aqueduct counter is off by one." } })
      fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The aqueduct counter is off by one.")
      expect((form.get("screenshot") as File).name).toBe("bug-report-full-page.png")
      expect(await screen.findByRole("status")).toHaveTextContent("Bug report queued.")
      expect(screen.queryByRole("dialog", { name: "Report a bug" })).not.toBeInTheDocument()
    } finally {
      script.remove()
    }
  })

  it("does not capture full-page bug report screenshots until selected", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      fireEvent.click((await screen.findAllByRole("button", { name: "Report a bug" }))[0])
      expect(await screen.findByRole("dialog", { name: "Report a bug" })).toBeInTheDocument()

      expect(html2canvasMock).toHaveBeenCalledTimes(1)
      expect(html2canvasMock).toHaveBeenLastCalledWith(
        document.body,
        expect.objectContaining({
          width: window.innerWidth,
          height: window.innerHeight,
          windowWidth: window.innerWidth,
          windowHeight: window.innerHeight
        })
      )
    } finally {
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("scales oversized full-page bug report screenshots instead of rejecting them", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8") {
        return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByRole("main", { name: "Chat" })).toBeInTheDocument()
      fireEvent.click((await screen.findAllByRole("button", { name: "Report a bug" }))[0])
      expect(await screen.findByRole("dialog", { name: "Report a bug" })).toBeInTheDocument()

      Object.defineProperty(document.body, "scrollWidth", { configurable: true, value: 4000 })
      Object.defineProperty(document.body, "scrollHeight", { configurable: true, value: 4000 })
      Object.defineProperty(document.documentElement, "scrollWidth", { configurable: true, value: 4000 })
      Object.defineProperty(document.documentElement, "scrollHeight", { configurable: true, value: 4000 })

      fireEvent.click(screen.getByRole("radio", { name: "Full page" }))
      await waitFor(() => expect(html2canvasMock).toHaveBeenCalledTimes(2))
      const fullPageCall = html2canvasMock.mock.calls[1] as unknown as [
        HTMLElement,
        { scale?: number; scrollX?: number; scrollY?: number; width?: number; height?: number }
      ]
      const options = fullPageCall[1]

      expect(options).toEqual(
        expect.objectContaining({
          width: 4000,
          height: 4000,
          scrollX: 0,
          scrollY: 0
        })
      )
      expect(options.scale).toBeCloseTo(Math.sqrt(8_000_000 / 16_000_000))
      expect(screen.getByRole("radio", { name: "Full page" })).toBeChecked()
      expect(screen.queryByText("Full-page screenshot capture failed. The viewport screenshot is still available.")).not.toBeInTheDocument()
    } finally {
      delete (document.body as { scrollWidth?: number }).scrollWidth
      delete (document.body as { scrollHeight?: number }).scrollHeight
      delete (document.documentElement as { scrollWidth?: number }).scrollWidth
      delete (document.documentElement as { scrollHeight?: number }).scrollHeight
      fetchSpy.mockRestore()
      script.remove()
    }
  })

  it("submits bug reports without a screenshot when that option is selected", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Bug report queued.", job_id: 45 }), { status: 201, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click((await screen.findAllByRole("button", { name: "Report a bug" }))[0])
      await screen.findByRole("dialog", { name: "Report a bug" })
      fireEvent.click(screen.getByRole("radio", { name: "No screenshot" }))
      fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("screenshot")).toBeNull()
    } finally {
      script.remove()
    }
  })

  it("accepts bug reports with the command-enter shortcut", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/bug_reports" && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ message: "Bug report queued.", job_id: 46 }), { status: 201, headers: { "Content-Type": "application/json" } })
        )
      }

      return Promise.reject(new Error(`Unexpected fetch: ${path}`))
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      fireEvent.click((await screen.findAllByRole("button", { name: "Report a bug" }))[0])
      await screen.findByRole("dialog", { name: "Report a bug" })
      fireEvent.change(screen.getByLabelText("Description"), { target: { value: "The toga modal has fallen." } })
      fireEvent.keyDown(screen.getByLabelText("Description"), { key: "Enter", metaKey: true })

      await waitFor(() => {
        expect(fetchSpy).toHaveBeenCalledWith(
          "/api/v1/app/bug_reports",
          expect.objectContaining({ method: "POST", credentials: "same-origin", body: expect.any(FormData) })
        )
      })
      const form = fetchSpy.mock.calls.find((call) => call[0] === "/api/v1/app/bug_reports")?.[1]?.body as FormData
      expect(form.get("title")).toBe("Dashboard bug")
      expect(form.get("description")).toBe("The toga modal has fallen.")
    } finally {
      script.remove()
    }
  })
})
