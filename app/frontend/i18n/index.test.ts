import { afterEach, describe, expect, it } from "vitest"
import i18n, { coreNamespaces, i18nReady, loadPluginLocales } from "."

describe("lazy locale loading", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("loads every core namespace when the active language changes", async () => {
    await i18nReady
    await i18n.changeLanguage("de")

    for (const namespace of coreNamespaces) {
      expect(i18n.hasResourceBundle("de", namespace)).toBe(true)
    }
    expect(i18n.t("common:loading")).not.toBe("common:loading")
  })

  it("loads a plugin namespace through its plugin lazy boundary", async () => {
    await i18n.changeLanguage("de")
    await loadPluginLocales("git_history")

    expect(i18n.hasResourceBundle("de", "git_history")).toBe(true)
    expect(i18n.hasResourceBundle("en", "git_history")).toBe(true)
  })
})
