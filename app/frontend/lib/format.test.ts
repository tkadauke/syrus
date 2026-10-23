import { afterEach, describe, expect, it } from "vitest"
import i18n from "../i18n"
import { formatBytes, formatCurrency, formatNumber, pluralCategory } from "./format"

afterEach(async () => {
  await i18n.changeLanguage("en")
})

describe("formatBytes", () => {
  it("formats B / KB / MB", () => {
    expect(formatBytes(0)).toBe("0 B")
    expect(formatBytes(512)).toBe("512 B")
    expect(formatBytes(2048)).toBe("2.0 KB")
    expect(formatBytes(5 * 1024 * 1024)).toBe("5.0 MB")
  })

  it("returns 'unknown size' for null/undefined", () => {
    expect(formatBytes(null)).toBe("unknown size")
    expect(formatBytes(undefined)).toBe("unknown size")
  })
})

describe("formatCurrency", () => {
  it("formats USD with four decimals by default", () => {
    expect(formatCurrency(1.23456)).toBe("$1.2346")
  })

  it("accepts an explicit precision", () => {
    expect(formatCurrency(1.23456, 2)).toBe("$1.23")
  })

  it("uses the active locale", async () => {
    await i18n.changeLanguage("de")

    expect(formatCurrency(1234.5, 2)).toMatch(/1\.234,50/)
  })
})

describe("locale-aware number and plural helpers", () => {
  it("formats numbers with the active locale", async () => {
    await i18n.changeLanguage("de")

    expect(formatNumber(1234.5)).toBe("1.234,5")
  })

  it("selects the locale's plural category", async () => {
    await i18n.changeLanguage("de")

    expect(pluralCategory(1)).toBe("one")
    expect(pluralCategory(2)).toBe("other")
  })
})
