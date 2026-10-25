import { beforeEach, describe, expect, it, vi } from "vitest"
import { createElectronI18n } from "../electron/i18nRuntime"

const getLocale = vi.fn<() => string>()
const { appLocale, t } = createElectronI18n(getLocale)

describe("Electron i18n", () => {
  beforeEach(() => getLocale.mockReset())

  it("uses Electron's normalized app locale", () => {
    getLocale.mockReturnValue("de-DE")

    expect(appLocale()).toBe("de")
    expect(t("shell.open")).toBe("Syrus oeffnen")
    expect(t("dialog.update_backend")).toBe("Syrus-Backend aktualisieren?")
    expect(t("dialog.update_backend_detail_pinned", { image: "next", current: "old" })).toContain("next")
    expect(t("dialog.uninstall_data", { app: "Syrus Test" })).toContain("Syrus Test")
    expect(t("screen.share")).toBe("Bildschirm teilen")
  })

  it("falls back to English for an unsupported app locale", () => {
    getLocale.mockReturnValue("fr-FR")

    expect(appLocale()).toBe("en")
    expect(t("shell.open")).toBe("Open Syrus")
  })
})
