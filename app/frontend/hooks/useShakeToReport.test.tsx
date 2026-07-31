import { renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { useShakeToReport } from "./useShakeToReport"

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

describe("useShakeToReport", () => {
  const OriginalDeviceMotionEvent = window.DeviceMotionEvent

  beforeEach(() => {
    const MockDeviceMotionEvent = class extends Event {}
    Object.defineProperty(window, "DeviceMotionEvent", { configurable: true, value: MockDeviceMotionEvent })
    Object.defineProperty(globalThis, "DeviceMotionEvent", { configurable: true, value: MockDeviceMotionEvent })
  })

  afterEach(() => {
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
})
