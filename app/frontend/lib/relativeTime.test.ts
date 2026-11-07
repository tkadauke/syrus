import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("../i18n", () => ({
  default: { language: "en" }
}))

import i18n from "../i18n"
import { calendarDayKey, formatRelativeDate, intlLocale, validTimeZone } from "./relativeTime"

const ONE_DAY_MS = 24 * 60 * 60 * 1000

describe("relativeTime", () => {
  afterEach(() => {
    ;(i18n as any).language = "en"
  })

  describe("intlLocale", () => {
    it("passes 'en' through unchanged", () => {
      expect(intlLocale()).toBe("en")
    })

    it("passes 'de' through unchanged", () => {
      ;(i18n as any).language = "de"
      expect(intlLocale()).toBe("de")
    })

    it("maps 'la' to 'en' since Latin is not represented in browser Intl ICU data", () => {
      ;(i18n as any).language = "la"
      expect(intlLocale()).toBe("en")
    })

    it("defaults to 'en' when language is not yet set", () => {
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
      ;(i18n as any).language = "de"
      const yesterday = new Date(Date.now() - ONE_DAY_MS)
      expect(formatRelativeDate(yesterday)).toBe("gestern")
    })

    it("formats in English for Latin locale (Intl has no Latin data)", () => {
      ;(i18n as any).language = "la"
      const yesterday = new Date(Date.now() - ONE_DAY_MS)
      expect(formatRelativeDate(yesterday)).toBe("yesterday")
    })

    it("formats hours with the active locale", () => {
      ;(i18n as any).language = "de"
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000)
      expect(formatRelativeDate(twoHoursAgo)).toBe("vor 2 Stunden")
    })

    it("accepts an explicit now timestamp", () => {
      const anchor = new Date("2026-01-01T12:00:00Z").getTime()
      const oneDayBefore = new Date("2025-12-31T12:00:00Z")
      expect(formatRelativeDate(oneDayBefore, anchor)).toBe("yesterday")
    })

    it("uses the selected timezone for calendar phrases across midnight", () => {
      const now = new Date("2026-01-02T08:30:00Z").getTime()
      const date = new Date("2026-01-01T08:45:00Z")
      expect(formatRelativeDate(date, now, "America/Los_Angeles")).toBe("yesterday")
      expect(calendarDayKey(new Date("2026-01-02T00:30:00Z"), "America/Los_Angeles")).toBe("2026-01-01")
      expect(calendarDayKey(new Date("2026-01-02T00:30:00Z"), "Asia/Tokyo")).toBe("2026-01-02")
    })

    it("recognizes 23-hour and 25-hour DST days as yesterday", () => {
      expect(formatRelativeDate(new Date("2026-03-08T17:00:00Z"), new Date("2026-03-09T16:00:00Z").getTime(), "America/New_York")).toBe("yesterday")
      expect(formatRelativeDate(new Date("2026-11-01T17:00:00Z"), new Date("2026-11-02T18:00:00Z").getTime(), "America/New_York")).toBe("yesterday")
    })
  })

  it("falls back safely for an invalid browser timezone", () => {
    expect(validTimeZone("Not/AZone")).toBe("UTC")
    expect(calendarDayKey(new Date("2026-01-01T23:30:00Z"), "Not/AZone")).toBe("2026-01-01")
  })
})
