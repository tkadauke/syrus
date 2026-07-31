import { describe, expect, it } from "vitest"
import { parseScheduleCommandArgs, parseScheduleTime } from "./scheduleTime"

describe("parseScheduleTime", () => {
  const now = new Date(2026, 6, 30, 15, 30)

  it("parses shorthand relative times", () => {
    expect(parseScheduleTime("30m", now)?.getTime()).toBe(now.getTime() + 30 * 60 * 1000)
    expect(parseScheduleTime("2h", now)?.getTime()).toBe(now.getTime() + 2 * 60 * 60 * 1000)
    expect(parseScheduleTime("1d", now)?.getTime()).toBe(now.getTime() + 24 * 60 * 60 * 1000)
  })

  it("parses relative phrases", () => {
    expect(parseScheduleTime("in 1 hour", now)?.getTime()).toBe(now.getTime() + 60 * 60 * 1000)
  })

  it("parses tomorrow with an optional clock", () => {
    expect(localParts(parseScheduleTime("tomorrow", now))).toEqual([2026, 6, 31, 9, 0])
    expect(localParts(parseScheduleTime("tomorrow 9am", now))).toEqual([2026, 6, 31, 9, 0])
  })

  it("rolls same-day clock values to tomorrow when needed", () => {
    expect(localParts(parseScheduleTime("14:00", now))).toEqual([2026, 6, 31, 14, 0])
    expect(localParts(parseScheduleTime("16:00", now))).toEqual([2026, 6, 30, 16, 0])
  })
})

describe("parseScheduleCommandArgs", () => {
  const now = new Date(2026, 6, 30, 15, 30)

  it("splits a shorthand time prefix from the message", () => {
    expect(parseScheduleCommandArgs("2h ask about JOB-1234", now)).toEqual({
      fireAt: new Date(now.getTime() + 2 * 60 * 60 * 1000),
      body: "ask about JOB-1234"
    })
  })

  it("splits multi-token time prefixes from the message", () => {
    const tomorrow = parseScheduleCommandArgs("tomorrow 9am ask about deploy", now)
    expect(tomorrow?.body).toBe("ask about deploy")
    expect(localParts(tomorrow?.fireAt ?? null)).toEqual([2026, 6, 31, 9, 0])
    expect(parseScheduleCommandArgs("in 1 hour check queue", now)).toEqual({
      fireAt: new Date(now.getTime() + 60 * 60 * 1000),
      body: "check queue"
    })
  })

  it("returns null when time or message is missing", () => {
    expect(parseScheduleCommandArgs("", now)).toBeNull()
    expect(parseScheduleCommandArgs("2h", now)).toBeNull()
    expect(parseScheduleCommandArgs("later check queue", now)).toBeNull()
  })
})

function localParts(date: Date | null | undefined) {
  if (!date) return null

  return [
    date.getFullYear(),
    date.getMonth(),
    date.getDate(),
    date.getHours(),
    date.getMinutes()
  ]
}
