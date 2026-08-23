import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"

const reloadMock = vi.hoisted(() => vi.fn())

vi.mock("../lib/pageReload", () => ({
  reloadPage: reloadMock
}))

import { AdminSettings } from "./AdminSettings"
import * as useConfirmModule from "../hooks/useConfirm"

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
      mode: "advanced",
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
  let mockConfirm: ReturnType<typeof vi.fn>

  beforeEach(() => {
    mockConfirm = vi.fn().mockResolvedValue(true)
    vi.spyOn(useConfirmModule, "useConfirm").mockReturnValue({ confirm: mockConfirm as any, dialog: <></> })
    reloadMock.mockClear()
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

  it("confirms and reloads when saving a mode change", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(adminPayload({
          message: "Settings updated.",
          settings: { ...adminPayload().settings, mode: "simple" }
        })))
      }
      return Promise.resolve(jsonResponse(adminPayload()))
    })

    renderRoute()

    fireEvent.change(await screen.findByLabelText("Instance mode"), { target: { value: "simple" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(mockConfirm).toHaveBeenCalledWith(expect.objectContaining({
        message: expect.stringContaining("Simple mode hides developer-only surfaces")
      }))
    })
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings", expect.objectContaining({ method: "PATCH" }))
      expect(reloadMock).toHaveBeenCalled()
    })
  })

  it("resets the dropdown when cancelling a mode change", async () => {
    mockConfirm.mockResolvedValue(false)
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(adminPayload()))

    renderRoute()

    const modeSelect = await screen.findByLabelText("Instance mode")
    fireEvent.change(modeSelect, { target: { value: "simple" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(modeSelect).toHaveValue("advanced")
    })
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/admin/settings", expect.objectContaining({ method: "PATCH" }))
    expect(reloadMock).not.toHaveBeenCalled()
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
    vi.spyOn(window, "confirm").mockReturnValue(true)
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

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/settings/clear_secret", expect.objectContaining({
        method: "POST",
        body: JSON.stringify({ secret: "discord_bot_token" })
      }))
    })
  })

  it("does not double-render the Discord secret in the generic secrets list", async () => {
    renderRoute()

    await discordSection()
    expect(screen.queryByText("Discord bot token")).not.toBeInTheDocument()
  })
})
