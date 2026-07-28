import { useEffect, useRef } from "react"

const SHAKE_THRESHOLD = 15 // m/s²
const CONSECUTIVE_FRAMES_NEEDED = 2

type DeviceMotionEventWithPermission = typeof DeviceMotionEvent & {
  requestPermission?: () => Promise<PermissionState>
}

export function useShakeToReport(onShake: () => void) {
  const onShakeRef = useRef(onShake)
  const consecutiveRef = useRef(0)

  useEffect(() => {
    onShakeRef.current = onShake
  })

  useEffect(() => {
    if (typeof window === "undefined" || !("DeviceMotionEvent" in window)) return

    function handleMotion(event: DeviceMotionEvent) {
      const accel = event.accelerationIncludingGravity
      if (!accel) return
      const x = accel.x ?? 0
      const y = accel.y ?? 0
      const z = accel.z ?? 0
      const magnitude = Math.sqrt(x * x + y * y + z * z)
      if (magnitude > SHAKE_THRESHOLD) {
        consecutiveRef.current++
        if (consecutiveRef.current >= CONSECUTIVE_FRAMES_NEEDED) {
          consecutiveRef.current = 0
          onShakeRef.current()
        }
      } else {
        consecutiveRef.current = 0
      }
    }

    const DME = DeviceMotionEvent as DeviceMotionEventWithPermission

    if (typeof DME.requestPermission === "function") {
      // iOS 13+: DeviceMotionEvent requires an explicit user-gesture permission grant.
      // Request on the first user click to avoid prompting on page load.
      let requested = false

      async function requestOnClick() {
        if (requested) return
        requested = true
        document.removeEventListener("click", requestOnClick, true)
        try {
          const permission = await DME.requestPermission!()
          if (permission === "granted") {
            window.addEventListener("devicemotion", handleMotion)
          }
        } catch {
          // Denied or unavailable
        }
      }

      document.addEventListener("click", requestOnClick, true)
      return () => {
        document.removeEventListener("click", requestOnClick, true)
        window.removeEventListener("devicemotion", handleMotion)
      }
    }

    window.addEventListener("devicemotion", handleMotion)
    return () => window.removeEventListener("devicemotion", handleMotion)
  }, [])
}
