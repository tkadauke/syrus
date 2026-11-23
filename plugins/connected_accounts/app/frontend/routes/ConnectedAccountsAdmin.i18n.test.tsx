import { Suspense } from "react"
import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import i18n from "@app/i18n"
import { ProviderSettingsNotice } from "./ConnectedAccountsAdmin"

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
        />
      </Suspense>
    )

    expect(await screen.findByText(/Registriere deinen eigenen Google-OAuth-Client/)).toBeInTheDocument()
    expect(screen.queryByText(englishFallback)).not.toBeInTheDocument()
  })
})
