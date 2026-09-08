import { describe, expect, it } from "vitest"
import { explainCronSchedule, formatAge, formatBytes, formatMillicores } from "./k8sFormat"

describe("k8sFormat", () => {
  it("formats compact ages", () => {
    expect(formatAge("2026-01-01T00:00:00Z", new Date("2026-01-01T00:02:30Z"))).toBe("2m")
  })

  it("formats resource units", () => {
    expect(formatMillicores(1500)).toBe("1.50 vCPU")
    expect(formatBytes(1024 * 1024)).toBe("1.0 MB")
  })

  it("explains common Kubernetes CronJob schedules", () => {
    expect(explainCronSchedule("0 2 * * *")).toBe("Every day at 02:00")
    expect(explainCronSchedule("0 9 * * 1")).toBe("Every Monday at 09:00")
    expect(explainCronSchedule("*/15 * * * *")).toBe("Every 15 minutes")
    expect(explainCronSchedule("@weekly")).toBe("Every Sunday at 00:00")
  })

  it("returns null for unsupported cron shapes", () => {
    expect(explainCronSchedule("0 9 * * 1,3")).toBeNull()
    expect(explainCronSchedule("not cron")).toBeNull()
    expect(explainCronSchedule(null)).toBeNull()
  })
})
