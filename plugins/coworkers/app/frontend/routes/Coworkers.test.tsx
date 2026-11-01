import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, expect, it, vi } from "vitest"
import CoworkersRoute from "./Coworkers"

const grantCatalog = [
  "chat.message_owner",
  "chats.read_shared",
  "coworker.message",
  "coworker.spawn_chat",
  "schedule.manage_self",
  "workspace.files",
  "workspace.shell",
  "syrus.read_jobs",
  "syrus.propose_job"
].map((name) => ({
  name,
  label: name,
  description: name,
  maximum_policy: "auto" as const,
  tools: [],
  scopeable: false,
  default_enabled: true
}))

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
      path: "/coworkers/7",
      weekly_spend_usd: 0.75
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
  ],
  grant_catalog: grantCatalog,
  provisioning_attempts: []
}

const detailPayload = {
  coworker: {
    ...summaryPayload.coworkers[0],
    chat_provider: "codex",
    chat_model: "gpt-6.1-sol",
    effective_model: "gpt-6.1-sol",
    workspace_repo: "https://github.com/acme/workspace.git",
    soul: "role: Researcher\n\nCurious and concise.",
    spend_usd: 1.25,
    chats: [{ id: 12, role: "main", title: "Maya", path: "/chats/12" }],
    available_chats: [{ id: 22, title: "Planning", rostered: false, implicit: false }],
    grants: [{ capability: "workspace.files", approval_policy: "auto", constraints: {} }],
    permission_cutover_report: {
      ready: false,
      legacy_grants: [{ capability: "workspace.files", approval_policy: "auto", effective_policy: "allow", scope: null, constraints: {} }],
      recommended_defaults: [],
      lost_authority: [],
      requestable_replacements: [],
      descriptor_gaps: [{ legacy_capability: "workspace.files", tools: [], reasons: ["missing explicit descriptors"] }],
      migration_errors: []
    },
    grant_catalog: grantCatalog,
    schedules: [
      {
        id: 31,
        name: "Morning briefing",
        prompt: "Prepare it",
        kind: "cron",
        state: "scheduled",
        schedule_input: "Every day at 9:00 AM",
        schedule_explanation: "Every day at 9:00 AM UTC",
        fire_at: null,
        next_fire_at: "2026-10-30T09:00:00Z",
        last_fired_at: null,
        after_run: "wake"
      },
      {
        id: 32,
        name: "Completed one-shot",
        prompt: "Prepare it once",
        kind: "one_shot",
        state: "fired",
        schedule_input: null,
        schedule_explanation: null,
        fire_at: "2026-10-29T09:00:00Z",
        next_fire_at: null,
        last_fired_at: "2026-10-29T09:00:00Z",
        after_run: "quiet"
      }
    ],
    message_traffic: {
      sent: 4,
      received: 7,
      window_days: 30,
      delivery_events: [{ status: "refused", receiver_handle: "rin", reason: "Three-hop limit reached", occurred_at: "2026-10-29T10:00:00Z" }]
    }
  }
}

const activityPayload = {
  spend: { week_usd: 0.75, total_usd: 1.25 },
  runs: [],
  side_chats: []
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

it("selects and submits a scope when creating a scoped grant", async () => {
  const scopedGrant = {
    name: "database.read",
    label: "Database",
    description: "Read a database",
    maximum_policy: "confirm" as const,
    tools: ["read_database"],
    scopeable: true,
    scope_options: [
      { value: 11, label: "Primary" },
      { value: 22, label: "Reporting" }
    ],
    default_enabled: false
  }
  const requests: Array<{ path: string; init?: RequestInit }> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input)
      requests.push({ path, init })
      if (path === "/api/v1/app/coworkers" && init?.method === "POST")
        return jsonResponse({ coworker: detailPayload.coworker, redirect_to: "/coworkers/7" }, 201)
      if (path === "/api/v1/app/coworkers/7") return jsonResponse(detailPayload)
      return jsonResponse({ ...summaryPayload, grant_catalog: [...grantCatalog, scopedGrant] })
    })
  )
  renderRoute("/coworkers/new")
  fill("Name", "Maya")
  fill("Handle", "maya")
  fill("Workspace remote", "https://github.com/acme/workspace")
  fireEvent.click(await screen.findByRole("checkbox", { name: "Database" }))
  fireEvent.change(screen.getByRole("combobox", { name: "Scope for Database" }), { target: { value: "22" } })
  fireEvent.click(screen.getByRole("button", { name: "Create coworker" }))
  await screen.findByRole("heading", { name: "Maya" })

  const form = requests.find(({ path, init }) => path === "/api/v1/app/coworkers" && init?.method === "POST")?.init?.body as FormData
  expect(form.get("grant_scopes[database.read]")).toBe("22")
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

it("adds a coworker to a selected chat from the coworker page", async () => {
  const requests: string[] = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = String(input)
      if (init?.method === "POST") requests.push(path)
      if (path === "/api/v1/app/coworkers/7") return jsonResponse(detailPayload)
      return jsonResponse({ agent: { id: 7 } }, 201)
    })
  )

  renderRoute("/coworkers/7")
  const selector = await screen.findByRole("combobox", { name: "Add to chat" })
  fireEvent.change(selector, { target: { value: "22" } })
  fireEvent.click(screen.getByRole("button", { name: "Add to chat" }))

  await waitFor(() => expect(requests).toContain("/api/v1/app/chats/22/agents/7"))
})

it("shows sent and received message traffic on the Activity tab", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => jsonResponse(String(input).endsWith("/activity") ? activityPayload : detailPayload))
  )
  renderRoute("/coworkers/7")

  fireEvent.click(await screen.findByRole("button", { name: "Activity" }))

  expect(await screen.findByRole("heading", { name: "Message traffic" })).toBeInTheDocument()
  expect(screen.getByRole("heading", { name: "Delivery issues" })).toBeInTheDocument()
  expect(screen.getByText("$1.25")).toBeInTheDocument()
  expect(screen.getByText("Shown for visibility; not capped.")).toBeInTheDocument()
  expect(screen.getByText("Message to @rin refused")).toBeInTheDocument()
  expect(screen.getByText("Three-hop limit reached")).toBeInTheDocument()
  expect(screen.getByText("Last 30 days")).toBeInTheDocument()
  expect(screen.getByText("4")).toBeInTheDocument()
  expect(screen.getByText("7")).toBeInTheDocument()
})

it("does not offer removal for the coworker's implicit own chat", async () => {
  const payload = {
    coworker: {
      ...detailPayload.coworker,
      available_chats: [{ id: 12, title: "Maya", rostered: false, implicit: true }]
    }
  }
  vi.stubGlobal(
    "fetch",
    vi.fn(async () => jsonResponse(payload))
  )

  renderRoute("/coworkers/7")
  const selector = await screen.findByRole("combobox", { name: "Add to chat" })
  fireEvent.change(selector, { target: { value: "12" } })

  expect(screen.getByRole("button", { name: "Add to chat" })).toBeDisabled()
  expect(screen.queryByRole("button", { name: "Remove from chat" })).not.toBeInTheDocument()
})

it("renders the custom profile, editable capabilities, and creates side chats", async () => {
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
  expect(screen.getByRole("heading", { name: "Permission cutover report" })).toBeInTheDocument()
  expect(screen.getByText("Blocked")).toBeInTheDocument()
  expect(screen.getByText(/workspace.files: missing explicit descriptors/)).toBeInTheDocument()
  expect(screen.getByText("This coworker can read and edit workspace files.")).toBeInTheDocument()
  expect(screen.getByText("Gmail")).toBeInTheDocument()
  expect(screen.getAllByText("Coming later")).toHaveLength(2)
  fireEvent.click(screen.getByRole("button", { name: "Chat" }))
  fireEvent.click(screen.getByRole("button", { name: "New side chat" }))
  expect(await screen.findByText("Chat destination")).toBeInTheDocument()
})

it("confirms grant escalation and refreshes the live tool surface", async () => {
  const confirm = vi.fn(() => true)
  vi.stubGlobal("confirm", confirm)
  const fetchSpy = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (init?.method === "PATCH") return jsonResponse(detailPayload)
    return jsonResponse(detailPayload)
  })
  vi.stubGlobal("fetch", fetchSpy)
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  fireEvent.change(screen.getByRole("combobox", { name: "Approval policy for workspace.shell" }), { target: { value: "confirm" } })

  expect(confirm).toHaveBeenCalledOnce()
  await waitFor(() =>
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/coworkers/7/grants",
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"confirmed":true') })
    )
  )
  await waitFor(() => expect(fetchSpy.mock.calls.filter(([input]) => String(input) === "/api/v1/app/coworkers/7")).toHaveLength(2))
})

it("preserves a scoped grant when changing its policy and allows disabling it", async () => {
  const descriptor = {
    name: "database.read",
    label: "Database",
    description: "Read a database",
    maximum_policy: "confirm" as const,
    tools: ["read_database"],
    scopeable: true,
    scope_options: [
      { value: 11, label: "Primary" },
      { value: 22, label: "Reporting" }
    ],
    default_enabled: false
  }
  const payload = {
    coworker: {
      ...detailPayload.coworker,
      grants: [{ capability: "database.read", approval_policy: "confirm", constraints: {}, scope: 22 }],
      grant_catalog: [...grantCatalog, descriptor]
    }
  }
  const requestBodies: Record<string, unknown>[] = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === "PATCH") requestBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>)
      return jsonResponse(payload)
    })
  )

  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  expect(screen.getByRole("combobox", { name: "Scope for Database" })).toHaveValue("22")
  expect(screen.getByText("Unlocks: read_database")).toBeInTheDocument()

  fireEvent.change(screen.getByRole("combobox", { name: "Approval policy for database.read" }), { target: { value: "queue" } })
  await waitFor(() => expect(requestBodies).toContainEqual(expect.objectContaining({ capability: "database.read", approval_policy: "queue", scope: 22 })))

  fireEvent.change(screen.getByRole("combobox", { name: "Approval policy for database.read" }), { target: { value: "off" } })
  await waitFor(() => expect(requestBodies).toContainEqual(expect.objectContaining({ capability: "database.read", approval_policy: "off", scope: 22 })))
})

it("sends the displayed default scope when enabling a scoped grant", async () => {
  const descriptor = {
    name: "database.read",
    label: "Database",
    description: "Read a database",
    maximum_policy: "confirm" as const,
    tools: ["read_database"],
    scopeable: true,
    scope_options: [
      { value: 11, label: "Primary" },
      { value: 22, label: "Reporting" }
    ],
    default_enabled: false
  }
  const payload = { coworker: { ...detailPayload.coworker, grants: [], grant_catalog: [...grantCatalog, descriptor] } }
  const requestBodies: Record<string, unknown>[] = []
  vi.stubGlobal(
    "confirm",
    vi.fn(() => true)
  )
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
      if (init?.method === "PATCH") requestBodies.push(JSON.parse(String(init.body)) as Record<string, unknown>)
      return jsonResponse(payload)
    })
  )

  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  expect(screen.getByRole("combobox", { name: "Scope for Database" })).toHaveValue("11")

  fireEvent.change(screen.getByRole("combobox", { name: "Approval policy for database.read" }), { target: { value: "confirm" } })

  await waitFor(() =>
    expect(requestBodies).toContainEqual(
      expect.objectContaining({
        capability: "database.read",
        approval_policy: "confirm",
        confirmed: true,
        scope: 11
      })
    )
  )
})

it("confirms before removing a protected workspace path", async () => {
  const payload = {
    coworker: {
      ...detailPayload.coworker,
      grants: [{ capability: "workspace.files", approval_policy: "confirm", constraints: { confirm_paths: ["SOUL.md", "AGENTS.md"] } }]
    }
  }
  const confirm = vi.fn(() => true)
  vi.stubGlobal("confirm", confirm)
  const fetchSpy = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (init?.method === "PATCH") return jsonResponse(payload)
    return jsonResponse(payload)
  })
  vi.stubGlobal("fetch", fetchSpy)
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Capabilities" }))
  fireEvent.change(screen.getByPlaceholderText("SOUL.md, AGENTS.md"), { target: { value: "SOUL.md" } })
  fireEvent.click(screen.getByRole("button", { name: "Save constraints" }))

  expect(confirm).toHaveBeenCalledOnce()
  await waitFor(() =>
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/coworkers/7/grants",
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"confirmed":true') })
    )
  )
})

it("shows pending approvals with the originating run and tool input and allows rejection", async () => {
  const invalidateQueries = vi.spyOn(QueryClient.prototype, "invalidateQueries")
  const fetchSpy = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const path = String(input)
    if (path.endsWith("/approvals") && !init?.method) {
      return jsonResponse({
        approvals: [
          {
            id: 91,
            tool_name: "propose_job",
            tool_input: { title: "Investigate" },
            run_id: 44,
            chat_id: 12,
            created_at: "2026-10-29T10:00:00Z",
            state: "pending",
            actor: { name: "Maya", handle: "maya", avatar_key: "comet", avatar_url: null, accent_hex: "#E5484D" }
          }
        ]
      })
    }
    if (path.endsWith("/reject")) return jsonResponse({ approval: { id: 91, state: "rejected" } })
    return jsonResponse(detailPayload)
  })
  vi.stubGlobal("fetch", fetchSpy)
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })

  fireEvent.click(screen.getByRole("button", { name: "Approvals" }))
  expect(await screen.findByText("Propose job")).toBeInTheDocument()
  expect(screen.getAllByText("Maya")).toHaveLength(2)
  expect(screen.getByText("Originating run 44")).toBeInTheDocument()
  expect(screen.getAllByText(/Investigate/)).toHaveLength(2)
  fireEvent.click(screen.getByRole("button", { name: "Reject" }))

  await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/coworkers/7/approvals/91/reject", expect.objectContaining({ method: "POST" })))
  await waitFor(() => expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["sidebar_badge", "coworkers.index"] }))
})

it("browses, searches, and renders coworker memory without write controls", async () => {
  const requests: string[] = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input)
      requests.push(path)
      if (path.includes("/memory")) {
        const matches = path.includes("search=evidence")
          ? [{ path: "memory/people/thomas.md", category: "people", name: "thomas", content: "Thomas likes **evidence**.", truncated: false }]
          : [
              { path: "memory/daily/2026-10-29.md", category: "daily", name: "2026-10-29", content: "# Today\n\nShipped it.", truncated: false },
              { path: "memory/people/thomas.md", category: "people", name: "thomas", content: "Thomas likes **evidence**.", truncated: false }
            ]
        return jsonResponse({ files: matches, search: "", truncated: false, partial: false, search_incomplete: false })
      }
      return jsonResponse(detailPayload)
    })
  )
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Memory" }))
  expect(await screen.findByRole("heading", { name: "2026-10-29" })).toBeInTheDocument()
  expect(screen.getByRole("heading", { name: "Today" })).toBeInTheDocument()
  expect(screen.getByRole("link", { name: "Open your Syrus memories" })).toHaveAttribute("href", "/memories")
  expect(screen.queryByRole("button", { name: /edit|save|delete/i })).not.toBeInTheDocument()

  fireEvent.click(screen.getByRole("button", { name: /add filter/i }))
  fireEvent.change(screen.getByRole("searchbox"), { target: { value: "evidence" } })
  fireEvent.click(screen.getByRole("button", { name: "Search for evidence" }))
  expect(await screen.findByRole("heading", { name: "thomas" })).toBeInTheDocument()
  expect(requests.some((path) => path.includes("search=evidence"))).toBe(true)
})

it("shows clear empty and unreachable memory states", async () => {
  let unavailable = false
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).includes("/memory"))
        return unavailable
          ? jsonResponse({ error: { message: "offline" } }, 503)
          : jsonResponse({ files: [], search: "", truncated: false, partial: false, search_incomplete: false })
      return jsonResponse(detailPayload)
    })
  )
  const view = renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Memory" }))
  expect(await screen.findByText("This coworker has no memory yet.")).toBeInTheDocument()

  unavailable = true
  view.unmount()
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Memory" }))
  expect(await screen.findByText("This coworker's memory cannot be reached right now.")).toBeInTheDocument()
})

it("does not claim that an incomplete search has no matches", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).includes("/memory")) return jsonResponse({ files: [], search: "needle", truncated: true, partial: true, search_incomplete: true })
      return jsonResponse(detailPayload)
    })
  )
  renderRoute("/coworkers/7?search=needle")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Memory" }))

  expect(await screen.findByText("Some memory content could not be searched. These results may be incomplete.")).toBeInTheDocument()
  expect(screen.queryByText("No memory files match this search.")).not.toBeInTheDocument()
})

it("warns when the workspace tree and selected file are truncated", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const path = String(input)
      if (path.includes("/workspace"))
        return jsonResponse({
          remote: "https://github.com/acme/workspace.git",
          branch: "coworkers/maya",
          files: [{ path: "README.md", type: "file" }],
          partial: true,
          selected_file: path.includes("path=") ? { path: "README.md", content: "# Partial", truncated: true, binary: false } : null,
          commits: [],
          conflicts: []
        })
      return jsonResponse(detailPayload)
    })
  )
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Workspace" }))

  expect(await screen.findByText("This workspace tree is incomplete. Only the available files are shown.")).toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "README.md" }))
  expect(await screen.findByText("This large file is shown in part.")).toBeInTheDocument()
  expect(screen.queryByRole("button", { name: /edit|save|delete/i })).not.toBeInTheDocument()
})

it("renders chat, run, and unavailable commit provenance honestly", async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      if (String(input).includes("/workspace"))
        return jsonResponse({
          remote: "https://github.com/acme/workspace.git",
          branch: "coworkers/maya",
          files: [],
          partial: false,
          selected_file: null,
          commits: [
            { sha: "a".repeat(40), message: "Chat change", authored_at: null, source: "chat", source_id: 91 },
            { sha: "b".repeat(40), message: "Run change", authored_at: null, source: "run", source_id: 42 },
            { sha: "c".repeat(40), message: "Seed", authored_at: null, source: "unattributed", source_id: null }
          ],
          conflicts: []
        })
      return jsonResponse(detailPayload)
    })
  )
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Workspace" }))

  expect(await screen.findByText("Chat 91")).toBeInTheDocument()
  expect(screen.getByText("Run 42")).toBeInTheDocument()
  expect(screen.getByText("Source unavailable")).toBeInTheDocument()
})

it("lists and manages schedules on the coworker page", async () => {
  const fetchSpy = vi.fn(async (_input: RequestInfo | URL, init?: RequestInit) => {
    if (init?.method === "POST") return jsonResponse({ schedule: detailPayload.coworker.schedules[0] })
    return jsonResponse(detailPayload)
  })
  vi.stubGlobal("fetch", fetchSpy)
  renderRoute("/coworkers/7")
  await screen.findByRole("heading", { name: "Maya" })
  fireEvent.click(screen.getByRole("button", { name: "Schedule" }))

  expect(screen.getByText("Morning briefing")).toBeInTheDocument()
  expect(screen.getByText(/Every day at 9:00 AM UTC/)).toBeInTheDocument()
  expect(screen.getByRole("combobox", { name: "After each run" })).toHaveValue("wake")
  const firedRow = screen.getByText("Completed one-shot").closest("li")
  expect(firedRow).not.toBeNull()
  expect(within(firedRow!).queryByRole("button", { name: "Resume" })).not.toBeInTheDocument()
  expect(within(firedRow!).queryByRole("button", { name: "Run now" })).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole("button", { name: "Run now" }))
  await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/coworkers/7/schedules/31/fire_now", expect.objectContaining({ method: "POST" })))
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
