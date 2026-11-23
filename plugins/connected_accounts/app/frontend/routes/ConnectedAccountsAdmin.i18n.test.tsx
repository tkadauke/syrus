import { Suspense } from "react"
import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n, { loadPluginLocales } from "@app/i18n"
import { ProviderSettingsNotice } from "./ConnectedAccountsAdmin"

vi.mock("@app/i18n", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@app/i18n")>()
  return { ...actual, loadPluginLocales: vi.fn(actual.loadPluginLocales) }
})

const englishFallback = "Register your own Google OAuth client."

afterEach(async () => {
  await i18n.changeLanguage("en")
})

describe("ProviderSettingsNotice", () => {
  it("renders the provider-owned active-locale translation", async () => {
    await i18n.changeLanguage("de")

    render(
      <Suspense fallback={<span>Loading translation</span>}>
        <ProviderSettingsNotice
          notice={englishFallback}
          i18nKey="google_workspace:settings.provider_notice"
          pluginName="google_workspace"
        />
      </Suspense>
    )

    expect(loadPluginLocales).toHaveBeenCalledWith("google_workspace")
    expect(await screen.findByText(/Registriere deinen eigenen Google-OAuth-Client/)).toBeInTheDocument()
    expect(screen.queryByText(englishFallback)).not.toBeInTheDocument()
  })
})
