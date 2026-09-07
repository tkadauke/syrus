import { describe, expect, it } from "vitest"
import { bangCommandText, isBangCommandMode } from "./bangCommand"

describe("bangCommand", () => {
  it("enters command mode when the draft starts with !", () => {
    expect(isBangCommandMode("!")).toBe(true)
    expect(isBangCommandMode("!ls -la")).toBe(true)
  })

  it("stays out of command mode for empty or non-! drafts", () => {
    expect(isBangCommandMode("")).toBe(false)
    expect(isBangCommandMode("hello")).toBe(false)
  })

  it("does not enter command mode when ! is not the first character", () => {
    expect(isBangCommandMode("hello!")).toBe(false)
  })

  it("extracts the command text after the leading !", () => {
    expect(bangCommandText("!ls -la")).toBe("ls -la")
    expect(bangCommandText("!")).toBe("")
  })

  it("returns null for command text outside command mode", () => {
    expect(bangCommandText("ls -la")).toBeNull()
  })
})
