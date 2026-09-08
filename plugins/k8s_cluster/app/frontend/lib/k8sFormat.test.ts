import { describe, expect, it } from "vitest"
import {
  explainCronSchedule,
  formatAge,
  formatBytes,
  formatKubernetesCpu,
  formatKubernetesMemory,
  formatMillicores,
  kubernetesCpuMillicores,
  kubernetesMemoryBytes
} from "./k8sFormat"

describe("kubernetesCpuMillicores", () => {
  it("parses whole cores and scaled Kubernetes CPU quantities", () => {
    expect(kubernetesCpuMillicores("4")).toBe(4000)
    expect(kubernetesCpuMillicores("3800m")).toBe(3800)
    expect(kubernetesCpuMillicores("250000000n")).toBe(250)
    expect(kubernetesCpuMillicores("1500000u")).toBe(1500)
  })
})

describe("kubernetesMemoryBytes", () => {
  it("parses Kubernetes memory quantities into bytes", () => {
    expect(kubernetesMemoryBytes("16373052Ki")).toBe(16_766_005_248)
    expect(kubernetesMemoryBytes("16Gi")).toBe(16 * 1024 ** 3)
    expect(kubernetesMemoryBytes("500M")).toBe(500_000_000)
    expect(kubernetesMemoryBytes("128974848")).toBe(128_974_848)
  })
})

describe("formatKubernetesCpu", () => {
  it("formats Kubernetes CPU quantities for display", () => {
    expect(formatKubernetesCpu("4")).toBe("4 vCPU")
    expect(formatKubernetesCpu("3800m")).toBe("3.8 vCPU")
    expect(formatKubernetesCpu(null)).toBe("-")
  })
})

describe("formatKubernetesMemory", () => {
  it("formats Kubernetes memory quantities for display", () => {
    expect(formatKubernetesMemory("16373052Ki")).toBe("15.6 GB")
    expect(formatKubernetesMemory("16Gi")).toBe("16.0 GB")
    expect(formatKubernetesMemory("mystery")).toBe("mystery")
    expect(formatKubernetesMemory(null)).toBe("-")
  })
})

describe("k8sFormat", () => {
  it("formats compact ages", () => {
    expect(formatAge("2026-01-01T00:00:00Z", new Date("2026-01-01T00:02:30Z"))).toBe("2m")
  })

  it("formats resource units", () => {
    expect(formatMillicores(1500)).toBe("1.50 vCPU")
    expect(formatBytes(1024 * 1024)).toBe("1.0 MB")
  })

  it("explains common Kubernetes CronJob schedules", () => {
    expect(explainCronSchedule("0 2 * * *")).toEqual({
      key: "cron_explanation_every_day_at",
      values: { time: "02:00" }
    })
    expect(explainCronSchedule("0 9 * * 1")).toEqual({
      key: "cron_explanation_every_weekday_at",
      values: { weekday: "cron_weekday_1", time: "09:00" }
    })
    expect(explainCronSchedule("*/15 * * * *")).toEqual({
      key: "cron_explanation_every_n_minutes",
      values: { count: 15 }
    })
    expect(explainCronSchedule("@weekly")).toEqual({
      key: "cron_explanation_every_weekday_at",
      values: { weekday: "cron_weekday_0", time: "00:00" }
    })
  })

  it("returns null for unsupported cron shapes", () => {
    expect(explainCronSchedule("0 9 * * 1,3")).toBeNull()
    expect(explainCronSchedule("not cron")).toBeNull()
    expect(explainCronSchedule(null)).toBeNull()
  })
})
