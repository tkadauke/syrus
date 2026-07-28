import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "../i18n"
import * as credentialsApi from "../api/credentials"
import type { CredentialsPayload } from "../api/credentials"
import { PreferencesRoute } from "./AccountSettings"

function makePayload(locale = "en"): CredentialsPayload {
  return {
    user: {
      id: 1,
      email_address: "user@example.com",
      name: null,
      first_name: null,
      last_name: null,
      display_name: "user@example.com",
      profile_location: null,
      profile_company: null,
      profile_website: null,
      github_handle: null,
      profile_bio: null,
      avatar_url: null,
      admin: false,
      role: "developer",
      agent_provider: "claude",
      chat_provider: null,
      codex_auth_mode: "api_key",
      agent_max_turns: 200,
      scheduling_paused: false,
      auto_approve_mode: "never",
      locale,
      notification_preferences: {
        desktop_job_implemented: true,
        desktop_job_failed: true
      }
    },
    credential_status: {
      github_token: false,
      claude_oauth_token: false,
      codex_api_key: false,
      codex_auth_json: false,
    gemini_api_key: false,
      api_token: null
    },
    github_rate_limit: null,
    options: {
      locales: ["en", "de", "la"],
      agent_providers: ["claude", "codex"],
      chat_providers: [],
      roles: ["developer", "product_owner"],
      codex_auth_modes: ["api_key", "chatgpt_login"],
      agent_max_turns: { min: 0, max: 1000 },
      clearable_credentials: [],
      auto_approve_modes: [
        { value: "never", label: "Never", preview: "No auto-approval." }
      ]
    }
  }
}

function renderPreferences(payload: CredentialsPayload) {
  vi.spyOn(credentialsApi, "fetchCredentials").mockResolvedValue(payload)
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/settings/preferences"]}>
          <Routes>
            <Route path="/settings/preferences" element={<PreferencesRoute />} />
          </Routes>
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("Language switcher", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders a language select with English, Deutsch, and Latina options", async () => {
    renderPreferences(makePayload("en"))

    const select = await screen.findByRole("combobox", { name: /language/i })
    expect(select).toBeInTheDocument()

    const options = Array.from(select.querySelectorAll("option")).map((o) => o.textContent)
    expect(options).toContain("English")
    expect(options).toContain("Deutsch")
    expect(options).toContain("Latina")
  })

  it("shows the user's stored locale as the selected value", async () => {
    renderPreferences(makePayload("de"))

    const select = await screen.findByRole("combobox", { name: /language/i })
    expect((select as HTMLSelectElement).value).toBe("de")
  })

  it("calls i18next.changeLanguage when the locale is changed", async () => {
    const changeLanguage = vi.spyOn(i18n, "changeLanguage").mockResolvedValue(undefined as unknown as ReturnType<typeof i18n.changeLanguage> extends Promise<infer T> ? T : never)
    renderPreferences(makePayload("en"))

    const select = await screen.findByRole("combobox", { name: /language/i })
    fireEvent.change(select, { target: { value: "la" } })

    await waitFor(() => {
      expect(changeLanguage).toHaveBeenCalledWith("la")
    })
  })

  it("sends the updated locale to the API when saving", async () => {
    const updateCredentials = vi.spyOn(credentialsApi, "updateCredentials").mockResolvedValue({
      ...makePayload("la"),
      message: "Credentials updated."
    })
    vi.spyOn(i18n, "changeLanguage").mockResolvedValue(undefined as unknown as ReturnType<typeof i18n.changeLanguage> extends Promise<infer T> ? T : never)
    renderPreferences(makePayload("en"))

    const select = await screen.findByRole("combobox", { name: /language/i })
    fireEvent.change(select, { target: { value: "la" } })

    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(updateCredentials).toHaveBeenCalledWith(
        expect.objectContaining({ locale: "la" })
      )
    })
  })
})
