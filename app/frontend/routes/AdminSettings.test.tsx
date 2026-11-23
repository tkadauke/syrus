import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"

import { AdminSettings } from "./AdminSettings"
import * as useConfirmModule from "../hooks/useConfirm"

function mockUseConfirm(confirmed: boolean) {
  const mockConfirm = vi.fn<ReturnType<typeof useConfirmModule.useConfirm>["confirm"]>().mockResolvedValue(confirmed)
  vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm, dialog: <></> })
  return mockConfirm
}

function adminPayload(overrides: Record<string, unknown> = {}) {
  return {
    settings: {
      signups_open: false,
      max_job_failures: 3,
      max_concurrent_agent_runs: 3,
      max_in_flight_workflows: 0,
      prepared_layer_cache_gb: 100,
      repository_full_poll_interval_hours: 24,
      proactive_rebase_commit_threshold: 1,
      show_work_unit_debug: false,
      rebase_failure_cooldown_minutes: 60,
      wakeup_chain_limit: 100,
      workflow_admission_control_enabled: true,
      workflow_admission_policy: "whole_workflow",
      workflow_admission_control_changed_at: null,
      workflow_admission_control_changed_by: null,
      video_retention_days: 7,
      video_storage_budget_mb: 2048,
      video_storage_budget_bytes: 2147483648,
      grade_max_iterations: 3,
      adversarial_review_rounds: 0,
      security_review_rounds: 0,
      main_concern_report_threshold: 2,
      report_issue_repo_slug: "tkadauke/syrus",
      chat_coding_workspace_budget_mb: 0,
      merge_train_max_size: 10,
      clearable_secrets: [{ key: "gemini_api_key", label: "Gemini API key", set: true }]
    },
    ...overrides
  }
}

function renderRoute() {
  if (!vi.isMockFunction(window.fetch)) {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(adminPayload())))
  }
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <AdminSettings />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminSettings numeric fields", () => {
  afterEach(() => vi.restoreAllMocks())

  it("saves security review rounds", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Settings updated." })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()
    fireEvent.change(await screen.findByLabelText("Security review rounds"), { target: { value: "2" } })
    fireEvent.click(screen.getByRole("button", { name: /^Save$/ }))

    await waitFor(() =>
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining('"security_review_rounds":2')
        })
      )
    )
  })

  it("omits a blank numeric setting instead of coercing it to zero", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Settings updated." })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()
    const input = await screen.findByLabelText("Max concurrent agent runs (global)")
    fireEvent.change(input, { target: { value: "" } })
    fireEvent.click(screen.getByRole("button", { name: /^Save$/ }))

    await waitFor(() => {
      const patchCall = fetchSpy.mock.calls.find(([, init]) => init?.method === "PATCH")
      expect(patchCall).toBeDefined()
      const body = JSON.parse(String(patchCall?.[1]?.body))
      expect(body.app_setting).not.toHaveProperty("max_concurrent_agent_runs")
    })
  })

  it("saves the in-flight workflow limit", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Settings updated." })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()
    const input = await screen.findByLabelText("Max in-flight workflows")
    fireEvent.change(input, { target: { value: "24" } })
    fireEvent.click(screen.getByRole("button", { name: /^Save$/ }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining('"max_in_flight_workflows":24')
        })
      )
    })
  })

  it("saves the wakeup chain limit", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Settings updated." })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()
    const input = await screen.findByLabelText("Wakeup chain limit")
    expect(input).toHaveValue(100)
    fireEvent.change(input, { target: { value: "250" } })
    fireEvent.click(screen.getByRole("button", { name: /^Save$/ }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining('"wakeup_chain_limit":250')
        })
      )
    })
  })

  it("preserves an explicitly entered zero", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Settings updated." })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()
    const input = await screen.findByLabelText("Max concurrent agent runs (global)")
    fireEvent.change(input, { target: { value: "0" } })
    fireEvent.click(screen.getByRole("button", { name: /^Save$/ }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          body: expect.stringContaining('"max_concurrent_agent_runs":0')
        })
      )
    })
  })
})

describe("AdminSettings SecretRow", () => {
  let mockConfirm: ReturnType<typeof mockUseConfirm>

  beforeEach(() => {
    mockConfirm = mockUseConfirm(true)
  })

  afterEach(() => vi.restoreAllMocks())

  it("opens confirm dialog instead of window.confirm when clearing a secret", async () => {
    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    fireEvent.click(clearButton)

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true }))
    })
  })

  it("calls the API when the user confirms", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/settings/clear_secret" && init?.method === "POST")
        return Promise.resolve(jsonResponse(adminPayload({ message: "Cleared." })))
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    fireEvent.click(clearButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.objectContaining({ method: "POST" }))
    })
  })

  it("does not call the API when the user cancels", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminPayload()))

    renderRoute()

    const clearButton = await screen.findByRole("button", { name: "Clear" })
    await act(async () => {
      fireEvent.click(clearButton)
    })

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalled()
    })
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.anything())
  })
})

describe("AdminSettings bot token sections", () => {
  afterEach(() => vi.restoreAllMocks())

  async function platformSection(name: "Telegram" | "Discord") {
    const heading = await screen.findByRole("heading", { name })
    const section = heading.closest("section")
    if (!section) throw new Error(`${name} section not found`)
    return within(section)
  }

  it.each(["Telegram", "Discord"] as const)("links %s's bot token to the connected accounts page instead of holding a token field", async (name) => {
    renderRoute()

    const section = await platformSection(name)
    const link = section.getByRole("link", { name: "Manage the bot token in Connected accounts" })
    expect(link).toHaveAttribute("href", "/admin/connected_accounts")
    expect(section.getByText(/instance-owned connected account/)).toBeInTheDocument()
    expect(section.queryByLabelText(/bot token/i)).not.toBeInTheDocument()
    expect(section.queryByRole("button", { name: "Save token" })).not.toBeInTheDocument()
    expect(section.queryByRole("button", { name: "Clear" })).not.toBeInTheDocument()
  })

  it("never sends a bot token through the settings endpoint", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminPayload()))
    renderRoute()

    await platformSection("Discord")
    const bodies = fetchSpy.mock.calls.map(([, init]) => String(init?.body ?? ""))
    expect(bodies.some((body) => body.includes("bot_token"))).toBe(false)
  })
})

describe("AdminSettings platform polling controls", () => {
  afterEach(() => vi.restoreAllMocks())

  function bothTokensSetPayload() {
    return adminPayload({
      settings: {
        ...adminPayload().settings,
        clearable_secrets: [{ key: "gemini_api_key", label: "Gemini API key", set: true }]
      }
    })
  }

  async function telegramSection() {
    const heading = await screen.findByRole("heading", { name: "Telegram" })
    const section = heading.closest("section")
    if (!section) throw new Error("Telegram section not found")
    return within(section)
  }

  async function discordSection() {
    const heading = await screen.findByRole("heading", { name: "Discord" })
    const section = heading.closest("section")
    if (!section) throw new Error("Discord section not found")
    return within(section)
  }

  function mockStartPolling() {
    return vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/platform_polling/start" && init?.method === "POST") {
        return Promise.resolve(
          jsonResponse({
            started: ["Discord::GatewayConnectionJob"],
            connectors: [
              { name: "Telegram::PollUpdatesJob", status: "already_running", platform: "telegram" },
              { name: "Discord::GatewayConnectionJob", status: "started", platform: "discord" }
            ]
          })
        )
      }
      return Promise.resolve(jsonResponse(bothTokensSetPayload()))
    })
  }

  it("enables both sections' Start polling buttons (the backend reports not_configured itself)", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(bothTokensSetPayload()))
    renderRoute()

    const telegram = await telegramSection()
    const discord = await discordSection()
    expect(telegram.getByRole("button", { name: "Start polling" })).not.toBeDisabled()
    expect(discord.getByRole("button", { name: "Start polling" })).not.toBeDisabled()
  })

  it("shows only Telegram's own resolved status after clicking Telegram's button, even though the shared call also started Discord", async () => {
    mockStartPolling()
    renderRoute()

    const telegram = await telegramSection()
    fireEvent.click(telegram.getByRole("button", { name: "Start polling" }))

    await waitFor(() => {
      expect(telegram.getByText("Telegram polling is already running.")).toBeInTheDocument()
    })

    const discord = await discordSection()
    expect(discord.queryByText(/Discord polling/)).not.toBeInTheDocument()
  })

  it("shows only Discord's own resolved status after clicking Discord's button", async () => {
    mockStartPolling()
    renderRoute()

    const discord = await discordSection()
    fireEvent.click(discord.getByRole("button", { name: "Start polling" }))

    await waitFor(() => {
      expect(discord.getByText("Discord polling started.")).toBeInTheDocument()
    })

    const telegram = await telegramSection()
    expect(telegram.queryByText(/Telegram polling/)).not.toBeInTheDocument()
  })
})
