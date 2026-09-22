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
      max_concurrent_agent_runs: 0,
      proactive_rebase_commit_threshold: 1,
      show_work_unit_debug: false,
      rebase_failure_cooldown_minutes: 60,
      video_retention_days: 7,
      video_storage_budget_mb: 2048,
      video_storage_budget_bytes: 2147483648,
      grade_max_iterations: 3,
      adversarial_review_rounds: 0,
      merge_train_enabled: false,
      merge_train_max_size: 10,
      clearable_secrets: [
        { key: "gemini_api_key", label: "Gemini API key", set: true },
        { key: "telegram_bot_token", label: "Telegram bot token", set: false },
        { key: "discord_bot_token", label: "Discord bot token", set: false }
      ]
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
      if (url === "/api/v1/app/admin/settings/clear_secret" && init?.method === "POST") return Promise.resolve(jsonResponse(adminPayload({ message: "Cleared." })))
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
    await act(async () => { fireEvent.click(clearButton) })

    await waitFor(() => { expect(mockConfirm).toHaveBeenCalled() })
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.anything())
  })
})

describe("AdminSettings Discord section", () => {
  afterEach(() => vi.restoreAllMocks())

  async function discordSection() {
    const heading = await screen.findByRole("heading", { name: "Discord" })
    const section = heading.closest("section")
    if (!section) throw new Error("Discord section not found")
    return within(section)
  }

  it("renders the Discord token input with a not-set status", async () => {
    renderRoute()

    const section = await discordSection()
    expect(section.getByLabelText("Discord bot token")).toBeInTheDocument()
    expect(section.getByText("Not set.")).toBeInTheDocument()
  })

  it("saves the Discord bot token", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({
          message: "Settings updated.",
          settings: {
            ...adminPayload().settings,
            clearable_secrets: [
              { key: "gemini_api_key", label: "Gemini API key", set: true },
              { key: "telegram_bot_token", label: "Telegram bot token", set: false },
              { key: "discord_bot_token", label: "Discord bot token", set: true }
            ]
          }
        })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()

    const section = await discordSection()
    const input = section.getByLabelText("Discord bot token")
    fireEvent.change(input, { target: { value: "discord-secret-token" } })
    fireEvent.click(section.getByRole("button", { name: "Save token" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ app_setting: { discord_bot_token: "discord-secret-token" } })
      }))
    })
  })

  it("clears the Discord bot token when set", async () => {
    const mockConfirm = mockUseConfirm(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/settings/clear_secret" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Cleared." })))
      }
      return Promise.resolve(jsonResponse(adminPayload({
        settings: {
          ...adminPayload().settings,
          clearable_secrets: [
            { key: "gemini_api_key", label: "Gemini API key", set: true },
            { key: "telegram_bot_token", label: "Telegram bot token", set: false },
            { key: "discord_bot_token", label: "Discord bot token", set: true }
          ]
        }
      })))
    })

    renderRoute()

    const section = await discordSection()
    fireEvent.click(section.getByRole("button", { name: "Clear" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true })))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ secret: "discord_bot_token" })
      }))
    })
  })

  it("clears the Telegram bot token through the shared confirm dialog", async () => {
    const mockConfirm = mockUseConfirm(true)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/settings/clear_secret" && init?.method === "POST") {
        return Promise.resolve(jsonResponse(adminPayload({ message: "Cleared." })))
      }
      return Promise.resolve(jsonResponse(adminPayload({
        settings: {
          ...adminPayload().settings,
          clearable_secrets: [
            { key: "gemini_api_key", label: "Gemini API key", set: true },
            { key: "telegram_bot_token", label: "Telegram bot token", set: true },
            { key: "discord_bot_token", label: "Discord bot token", set: false }
          ]
        }
      })))
    })

    renderRoute()

    const heading = await screen.findByRole("heading", { name: "Telegram" })
    const section = within(heading.closest("section") as HTMLElement)
    fireEvent.click(section.getByRole("button", { name: "Clear" }))

    await waitFor(() => expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({ destructive: true })))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ secret: "telegram_bot_token" })
      }))
    })
  })

  it("does not double-render the Discord secret in the generic secrets list", async () => {
    renderRoute()

    await discordSection()
    expect(screen.queryByText("Discord bot token")).not.toBeInTheDocument()
  })

  it("disables Discord's Start polling button until a bot token is set", async () => {
    renderRoute()

    const section = await discordSection()
    expect(section.getByRole("button", { name: "Start polling" })).toBeDisabled()
  })
})

describe("AdminSettings platform polling controls", () => {
  afterEach(() => vi.restoreAllMocks())

  function bothTokensSetPayload() {
    return adminPayload({
      settings: {
        ...adminPayload().settings,
        clearable_secrets: [
          { key: "gemini_api_key", label: "Gemini API key", set: true },
          { key: "telegram_bot_token", label: "Telegram bot token", set: true },
          { key: "discord_bot_token", label: "Discord bot token", set: true }
        ]
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
        return Promise.resolve(jsonResponse({
          started: ["Discord::GatewayConnectionJob"],
          connectors: [
            { name: "PollTelegramUpdatesJob", status: "already_running", platform: "telegram" },
            { name: "Discord::GatewayConnectionJob", status: "started", platform: "discord" }
          ]
        }))
      }
      return Promise.resolve(jsonResponse(bothTokensSetPayload()))
    })
  }

  it("enables both sections' Start polling buttons once each platform has a token", async () => {
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
