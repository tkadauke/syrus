import { beforeEach, describe, expect, it } from "vitest"
import { setElectronLocale } from "./test/electron"

describe("Electron i18n", () => {
  beforeEach(() => setElectronLocale("en"))

  it("uses Electron's normalized app locale", async () => {
    setElectronLocale("de-DE")
    const { appLocale, t } = await import("../electron/i18n")

    expect(appLocale()).toBe("de")
    expect(t("shell.open")).toBe("Syrus oeffnen")
    expect(t("dialog.update_backend")).toBe("Syrus-Backend aktualisieren?")
    expect(t("dialog.update_backend_detail_pinned", { image: "next", current: "old" })).toContain("next")
    expect(t("dialog.uninstall_data", { app: "Syrus Test" })).toContain("Syrus Test")
    expect(t("screen.share")).toBe("Bildschirm teilen")
  })

  it("falls back to English for an unsupported app locale", async () => {
    setElectronLocale("fr-FR")
    const { appLocale, t } = await import("../electron/i18n")

    expect(appLocale()).toBe("en")
    expect(t("shell.open")).toBe("Open Syrus")
  })
})
