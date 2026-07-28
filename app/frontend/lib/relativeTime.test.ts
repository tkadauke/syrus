import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("../i18n", () => ({
  default: { language: "en" }
}))

import i18n from "../i18n"
import { formatRelativeDate, intlLocale } from "./relativeTime"

const ONE_DAY_MS = 24 * 60 * 60 * 1000

describe("relativeTime", () => {
  afterEach(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(i18n as any).language = "en"
  })

  describe("intlLocale", () => {
    it("passes 'en' through unchanged", () => {
      expect(intlLocale()).toBe("en")
    })

    it("passes 'de' through unchanged", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = "de"
      expect(intlLocale()).toBe("de")
    })

    it("maps 'la' to 'en' since Latin is not represented in browser Intl ICU data", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = "la"
      expect(intlLocale()).toBe("en")
    })

    it("defaults to 'en' when language is not yet set", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = ""
      expect(intlLocale()).toBe("en")
    })
  })

  describe("formatRelativeDate", () => {
    it("formats in English by default", () => {
      const yesterday = new Date(Date.now() - ONE_DAY_MS)
      expect(formatRelativeDate(yesterday)).toBe("yesterday")
    })

    it("formats in the user's Syrus locale — German 'gestern' for yesterday", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = "de"
      const yesterday = new Date(Date.now() - ONE_DAY_MS)
      expect(formatRelativeDate(yesterday)).toBe("gestern")
    })

    it("formats in English for Latin locale (Intl has no Latin data)", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = "la"
      const yesterday = new Date(Date.now() - ONE_DAY_MS)
      expect(formatRelativeDate(yesterday)).toBe("yesterday")
    })

    it("formats hours with the active locale", () => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(i18n as any).language = "de"
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000)
      expect(formatRelativeDate(twoHoursAgo)).toBe("vor 2 Stunden")
    })

    it("accepts an explicit now timestamp", () => {
      const anchor = new Date("2026-01-01T12:00:00Z").getTime()
      const oneDayBefore = new Date("2025-12-31T12:00:00Z")
      expect(formatRelativeDate(oneDayBefore, anchor)).toBe("yesterday")
    })
  })
})
