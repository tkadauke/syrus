import { describe, expect, it } from "vitest"
import {
  formatKubernetesCpu,
  formatKubernetesMemory,
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
