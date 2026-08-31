import { describe, expect, it } from "vitest"
import { formatBytes, formatCurrency } from "./format"

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
})
