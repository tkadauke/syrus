import { act, renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { useShakeToReport } from "./useShakeToReport"
import { MOTION_PERMISSION_STORAGE_KEY } from "../lib/shakeToReportPermission"

type MotionInput = {
  acceleration?: DeviceMotionEventAcceleration | null
  accelerationIncludingGravity?: DeviceMotionEventAcceleration | null
  timeStamp?: number
}

function acceleration(x: number, y: number, z: number): DeviceMotionEventAcceleration {
  return { x, y, z } as DeviceMotionEventAcceleration
}

function dispatchMotion(input: MotionInput) {
  const event = new Event("devicemotion") as DeviceMotionEvent
  Object.defineProperty(event, "acceleration", { value: input.acceleration ?? null })
  Object.defineProperty(event, "accelerationIncludingGravity", { value: input.accelerationIncludingGravity ?? null })
  Object.defineProperty(event, "timeStamp", { value: input.timeStamp ?? 2000 })
  window.dispatchEvent(event)
}

async function clickDocument() {
  await act(async () => {
    document.dispatchEvent(new MouseEvent("click", { bubbles: true }))
  })
}

describe("useShakeToReport", () => {
  const OriginalDeviceMotionEvent = window.DeviceMotionEvent

  beforeEach(() => {
    const MockDeviceMotionEvent = class extends Event {}
    Object.defineProperty(window, "DeviceMotionEvent", { configurable: true, value: MockDeviceMotionEvent })
    Object.defineProperty(globalThis, "DeviceMotionEvent", { configurable: true, value: MockDeviceMotionEvent })
    window.localStorage.clear()
  })

  afterEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
    Object.defineProperty(window, "DeviceMotionEvent", { configurable: true, value: OriginalDeviceMotionEvent })
    Object.defineProperty(globalThis, "DeviceMotionEvent", { configurable: true, value: OriginalDeviceMotionEvent })
  })

  it("ignores motion that exceeded the old gravity-included threshold", () => {
    const onShake = vi.fn()
    renderHook(() => useShakeToReport(onShake))

    dispatchMotion({ accelerationIncludingGravity: acceleration(0, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(16, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-16, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(16, 0, 9.8) })

    expect(onShake).not.toHaveBeenCalled()
  })

  it("triggers after three strong gravity-included shake frames", () => {
    const onShake = vi.fn()
    renderHook(() => useShakeToReport(onShake))

    dispatchMotion({ accelerationIncludingGravity: acceleration(0, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-24, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8) })

    expect(onShake).toHaveBeenCalledOnce()
  })

  it("uses the lower threshold for gravity-free acceleration readings", () => {
    const onShake = vi.fn()
    renderHook(() => useShakeToReport(onShake))

    dispatchMotion({ acceleration: acceleration(0, 0, 0), accelerationIncludingGravity: acceleration(0, 0, 9.8) })
    dispatchMotion({ acceleration: acceleration(19, 0, 0), accelerationIncludingGravity: acceleration(19, 0, 9.8) })
    dispatchMotion({ acceleration: acceleration(-19, 0, 0), accelerationIncludingGravity: acceleration(-19, 0, 9.8) })
    dispatchMotion({ acceleration: acceleration(19, 0, 0), accelerationIncludingGravity: acceleration(19, 0, 9.8) })

    expect(onShake).toHaveBeenCalledOnce()
  })

  it("throttles repeated shake detections", () => {
    const onShake = vi.fn()
    renderHook(() => useShakeToReport(onShake))

    dispatchMotion({ accelerationIncludingGravity: acceleration(0, 0, 9.8), timeStamp: 2000 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8), timeStamp: 2010 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-24, 0, 9.8), timeStamp: 2020 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8), timeStamp: 2030 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-24, 0, 9.8), timeStamp: 2040 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8), timeStamp: 2050 })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-24, 0, 9.8), timeStamp: 2060 })

    expect(onShake).toHaveBeenCalledOnce()
  })

  it("persists granted iOS motion permission and reattaches motion handling on the next mount", async () => {
    const requestPermission = vi.fn<() => Promise<PermissionState>>().mockResolvedValue("granted")
    Object.defineProperty(window.DeviceMotionEvent, "requestPermission", {
      configurable: true,
      value: requestPermission,
    })

    const firstShake = vi.fn()
    const { unmount } = renderHook(() => useShakeToReport(firstShake))

    expect(requestPermission).not.toHaveBeenCalled()

    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()
    expect(window.localStorage.getItem(MOTION_PERMISSION_STORAGE_KEY)).toBe("granted")

    unmount()

    const secondShake = vi.fn()
    renderHook(() => useShakeToReport(secondShake))

    dispatchMotion({ accelerationIncludingGravity: acceleration(0, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(-24, 0, 9.8) })
    dispatchMotion({ accelerationIncludingGravity: acceleration(24, 0, 9.8) })

    expect(requestPermission).toHaveBeenCalledOnce()
    expect(secondShake).toHaveBeenCalledOnce()
  })

  it("persists denied iOS motion permission so later mounts do not ask again", async () => {
    const requestPermission = vi.fn<() => Promise<PermissionState>>().mockResolvedValue("denied")
    Object.defineProperty(window.DeviceMotionEvent, "requestPermission", {
      configurable: true,
      value: requestPermission,
    })

    const { unmount } = renderHook(() => useShakeToReport(vi.fn()))

    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()
    expect(window.localStorage.getItem(MOTION_PERMISSION_STORAGE_KEY)).toBe("denied")

    unmount()
    renderHook(() => useShakeToReport(vi.fn()))
    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()
  })

  it("persists unavailable iOS motion permission after request errors so later mounts do not ask again", async () => {
    const requestPermission = vi.fn<() => Promise<PermissionState>>().mockRejectedValue(new Error("blocked"))
    Object.defineProperty(window.DeviceMotionEvent, "requestPermission", {
      configurable: true,
      value: requestPermission,
    })

    const { unmount } = renderHook(() => useShakeToReport(vi.fn()))

    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()
    expect(window.localStorage.getItem(MOTION_PERMISSION_STORAGE_KEY)).toBe("unavailable")

    unmount()
    renderHook(() => useShakeToReport(vi.fn()))
    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()
  })

  it("falls back to per-mount first-click requests when storage is unavailable", async () => {
    const requestPermission = vi.fn<() => Promise<PermissionState>>().mockResolvedValue("granted")
    Object.defineProperty(window.DeviceMotionEvent, "requestPermission", {
      configurable: true,
      value: requestPermission,
    })
    vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
      throw new Error("storage unavailable")
    })
    vi.spyOn(Storage.prototype, "setItem").mockImplementation(() => {
      throw new Error("storage unavailable")
    })

    const { unmount } = renderHook(() => useShakeToReport(vi.fn()))

    await clickDocument()

    expect(requestPermission).toHaveBeenCalledOnce()

    unmount()
    renderHook(() => useShakeToReport(vi.fn()))
    await clickDocument()

    expect(requestPermission).toHaveBeenCalledTimes(2)
  })
})
