import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, expect, it, vi } from "vitest"
import CoworkersRoute from "./Coworkers"

const summaryPayload = {
  syrus: {
    id: "syrus",
    name: "Syrus",
    handle: "syrus",
    role_summary: "Engineer",
    state: "active",
    accent_hex: "#FBCFD3",
    avatar_key: null,
    avatar_url: null,
    path: "/coworkers/syrus",
    built_in: true
  },
  coworkers: [
    {
      id: 7,
      name: "Maya",
      handle: "maya",
      role_summary: "Researcher",
      state: "active",
      accent_hex: "#E5484D",
      avatar_key: "comet",
      avatar_url: null,
      path: "/coworkers/7"
    }
  ],
  model_options: [
    {
      provider: "codex",
      provider_label: "Codex",
      models: [
        { id: "gpt-6.1-sol", label: "GPT-6.1 Sol" },
        { id: "gpt-6.1-terra", label: "GPT-6.1 Terra" }
      ]
    }
  ]
}

const detailPayload = {
  coworker: {
    ...summaryPayload.coworkers[0],
    chat_provider: "codex",
    chat_model: "gpt-6.1-sol",
    effective_model: "gpt-6.1-sol",
    workspace_repo: "https://github.com/acme/workspace.git",
    soul: "role: Researcher\n\nCurious and concise.",
    chats: [{ id: 12, role: "main", title: "Maya", path: "/chats/12" }],
    grants: [{ capability: "workspace.files", approval_policy: "auto" }]
  }
}

afterEach(() => vi.unstubAllGlobals())

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

function renderRoute(path: string) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/coworkers" element={<CoworkersRoute />} />
          <Route path="/coworkers/new" element={<CoworkersRoute />} />
          <Route path="/coworkers/:id" element={<CoworkersRoute />} />
          <Route path="/chats/:id" element={<div>Chat destination</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function fill(label: string, value: string) {
  fireEvent.change(screen.getByLabelText(label), { target: { value } })
}

it("pins Syrus before custom coworkers and exposes creation", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse(summaryPayload))
  )
  renderRoute("/coworkers")
  const names = await screen.findAllByText(/Syrus|Maya/)
  expect(names.map((node) => node.textContent)).toEqual(["Syrus", "Maya"])
  expect(screen.getByRole("link", { name: /New coworker/i })).toHaveAttribute("href", "/coworkers/new")
})

it("tests the remote and submits appearance, upload, grants, and About", async () => {
  const requests: Array<{ path: string; init?: RequestInit }> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input)
      requests.push({ path, init })
      if (path.endsWith("/test_remote")) return jsonResponse({ message: "Push access verified." })
      if (path === "/api/v1/app/coworkers" && init?.method === "POST")
        return jsonResponse({ coworker: detailPayload.coworker, redirect_to: "/coworkers/7" }, 201)
      if (path === "/api/v1/app/coworkers/7") return jsonResponse(detailPayload)
      return jsonResponse(summaryPayload)
    })
  )
  renderRoute("/coworkers/new")
  fill("Name", "Maya")
  fill("Handle", "maya")
  expect(await screen.findByRole("option", { name: "GPT-6.1 Sol" })).toBeInTheDocument()
  fireEvent.change(screen.getByRole("combobox", { name: "Model" }), { target: { value: "codex:gpt-6.1-sol" } })
  fill("Workspace remote", "https://github.com/acme/workspace")
  fireEvent.click(screen.getByRole("button", { name: "Test push access" }))
  expect(await screen.findByText("Push access verified")).toBeInTheDocument()
  fireEvent.click(screen.getByRole("radio", { name: "Comet" }))
  expect(screen.queryByRole("button", { name: "Poppy" })).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: /#0090FF/ }))
  fireEvent.click(screen.getByRole("button", { name: "Poppy" }))
  expect(screen.getByRole("dialog", { name: "Color" })).toBeInTheDocument()
  fireEvent.click(screen.getByRole("checkbox", { name: "workspace.shell" }))
  fill("About (optional)", "Research lead")
  const upload = new File(["avatar"], "maya.png", { type: "image/png" })
  const fileInput = document.querySelector<HTMLInputElement>('input[name="avatar"]')
  fireEvent.change(fileInput!, { target: { files: [upload] } })
  fireEvent.click(screen.getByRole("button", { name: "Create coworker" }))
  expect(await screen.findByRole("heading", { name: "Maya" })).toBeInTheDocument()
  const request = requests.find(({ path, init }) => path === "/api/v1/app/coworkers" && init?.method === "POST")
  const form = request?.init?.body as FormData
  expect(form.get("accent_hex")).toBe("#E5484D")
  expect(form.get("chat_provider")).toBe("codex")
  expect(form.get("chat_model")).toBe("gpt-6.1-sol")
  expect(form.get("avatar_key")).toBe("comet")
  expect(form.get("avatar")).toBeInstanceOf(File)
  expect(form.getAll("grants[]")).not.toContain("workspace.shell")
  expect(form.get("about")).toBe("Research lead")
})

it("shows remote-test and creation errors without navigating", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const message = String(input).endsWith("/test_remote") ? "Push denied" : "Handle is unavailable"
      return jsonResponse({ error: { message } }, 422)
    })
  )
  renderRoute("/coworkers/new")
  fill("Name", "Maya")
  fill("Handle", "maya")
  fill("Workspace remote", "https://github.com/acme/workspace")
  fireEvent.click(screen.getByRole("button", { name: "Test push access" }))
  expect(await screen.findByText("Push denied")).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Create coworker" }))
  expect(await screen.findByText("Handle is unavailable")).toBeInTheDocument()
  expect(screen.getByRole("heading", { name: "New coworker" })).toBeInTheDocument()
})

it("renders the custom profile, creates side chats, and marks later tabs as stubs", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      if (String(input).endsWith("/chats") && init?.method === "POST") return jsonResponse({ chat_path: "/chats/44" }, 201)
      return jsonResponse(detailPayload)
    })
  )
  renderRoute("/coworkers/7")
  expect(await screen.findByRole("heading", { name: "Maya" })).toBeInTheDocument()
  expect(screen.getByRole("link", { name: "Main chat" })).toHaveAttribute("href", "/chats/12")
  fireEvent.click(screen.getByRole("button", { name: "Profile" }))
  expect(screen.getByText("gpt-6.1-sol")).toBeInTheDocument()
  expect(screen.getByText(/Curious and concise/)).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  expect(screen.getByText("Coming later")).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Chat" }))
  fireEvent.click(screen.getByRole("button", { name: "New side chat" }))
  expect(await screen.findByText("Chat destination")).toBeInTheDocument()
})

it("renders Syrus without a workspace or main chat and links its fixed surfaces", async () => {
  const fetchSpy = vi.fn()
  vi.stubGlobal("fetch", fetchSpy)
  renderRoute("/coworkers/syrus")
  expect(screen.getByRole("heading", { name: "Syrus" })).toBeInTheDocument()
  expect(screen.queryByText("Main chat")).not.toBeInTheDocument()
  expect(screen.queryByText("Workspace")).not.toBeInTheDocument()
  expect(screen.getByRole("link", { name: "Chats" })).toHaveAttribute("href", "/chats/search")
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  expect(screen.getByText("Fixed engineer capabilities")).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Schedule" }))
  expect(screen.getByRole("link", { name: "Schedule" })).toHaveAttribute("href", "/scheduled_tasks")
  fireEvent.click(screen.getByRole("button", { name: "Memory" }))
  expect(screen.getByRole("link", { name: "Memory" })).toHaveAttribute("href", "/memories")
  expect(fetchSpy).not.toHaveBeenCalled()
})
