import { describe, expect, it } from "vitest"
import { messages } from "./i18n"

const localizedLocales = ["de", "la"] as const

function placeholders(value: string) {
  return Array.from(value.matchAll(/\{\{(\w+)\}\}/g), (match) => match[1]).sort()
}

describe("desktop i18n messages", () => {
  it("keeps desktop locale keys identical across supported locales", () => {
    const englishKeys = Object.keys(messages.en).sort()

    for (const locale of localizedLocales) {
      expect(Object.keys(messages[locale]).sort()).toEqual(englishKeys)
    }
  })

  it("keeps interpolation placeholders identical to English", () => {
    const englishKeys = Object.keys(messages.en) as Array<keyof typeof messages.en>

    for (const locale of localizedLocales) {
      for (const key of englishKeys) {
        expect(placeholders(messages[locale][key])).toEqual(placeholders(messages.en[key]))
      }
    }
  })

  it("does not fall back to English for representative desktop UI surfaces", () => {
    const userVisibleKeys = [
      "repo_picker.select",
      "onboarding.welcome.title",
      "onboarding.connect.check_failed",
      "adopt_existing.keep",
      "port_conflict.title",
      "runtime.missing_title",
      "install_progress.title",
      "install_failed.title",
      "backend.remote.title"
    ] as const

    for (const locale of localizedLocales) {
      for (const key of userVisibleKeys) {
        expect(messages[locale][key]).not.toEqual(messages.en[key])
      }
    }
  })

  it("preserves destructive confirmation code tokens intentionally", () => {
    for (const locale of localizedLocales) {
      expect(messages[locale]["adopt_existing.confirm_word"]).toEqual("delete")
    }
  })
})
