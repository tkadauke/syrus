import { beforeEach, describe, expect, it, vi } from "vitest"

const { getLocale } = vi.hoisted(() => ({ getLocale: vi.fn() }))

vi.mock("electron", () => ({ app: { getLocale } }))

import { appLocale, t } from "../electron/i18n"

describe("Electron i18n", () => {
  beforeEach(() => getLocale.mockReset())

  it("uses Electron's base app locale", () => {
    getLocale.mockReturnValue("de-DE")
    expect(appLocale()).toBe("de")
    expect(t("menu.open")).toBe("Syrus oeffnen")
  })

  it("falls back to English for unsupported app locales", () => {
    getLocale.mockReturnValue("fr-FR")
    expect(appLocale()).toBe("en")
    expect(t("screen.share")).toBe("Share screen")
  })
})
