import { useEffect, useRef } from "react"

const SHAKE_ACCELERATION_THRESHOLD = 18 // m/s², when gravity-free acceleration is available
const SHAKE_ACCELERATION_WITH_GRAVITY_THRESHOLD = 24 // m/s²
const SHAKE_DELTA_THRESHOLD = 12 // m/s² frame-to-frame change
const CONSECUTIVE_FRAMES_NEEDED = 3
const SHAKE_COOLDOWN_MS = 1500
const MOTION_PERMISSION_STORAGE_KEY = "syrus:shake-to-report:motion-permission"

type PersistedMotionPermission = "granted" | "denied" | "unavailable"

type AccelerationVector = { x: number; y: number; z: number }

type DeviceMotionEventWithPermission = typeof DeviceMotionEvent & {
  requestPermission?: () => Promise<PermissionState>
}

function readPersistedMotionPermission(): PersistedMotionPermission | null {
  try {
    const permission = window.localStorage.getItem(MOTION_PERMISSION_STORAGE_KEY)
    if (permission === "granted" || permission === "denied" || permission === "unavailable") {
      return permission
    }
  } catch {
    // Storage can be unavailable in private browsing or locked-down embeds.
  }

  return null
}

function persistMotionPermission(permission: PersistedMotionPermission) {
  try {
    window.localStorage.setItem(MOTION_PERMISSION_STORAGE_KEY, permission)
  } catch {
    // Shake-to-report should still work when persistence is unavailable.
  }
}

export function useShakeToReport(onShake: () => void) {
  const onShakeRef = useRef(onShake)
  const consecutiveRef = useRef(0)
  const lastAccelerationRef = useRef<AccelerationVector | null>(null)
  const lastShakeAtRef = useRef(-SHAKE_COOLDOWN_MS)

  useEffect(() => {
    onShakeRef.current = onShake
  })

  useEffect(() => {
    if (typeof window === "undefined" || !("DeviceMotionEvent" in window)) return

    function handleMotion(event: DeviceMotionEvent) {
      const accel = event.acceleration ?? event.accelerationIncludingGravity
      if (!accel) return
      const x = accel.x ?? 0
      const y = accel.y ?? 0
      const z = accel.z ?? 0
      const previous = lastAccelerationRef.current
      lastAccelerationRef.current = { x, y, z }
      if (!previous) return

      const magnitude = Math.sqrt(x * x + y * y + z * z)
      const delta = Math.sqrt(
        (x - previous.x) ** 2 +
        (y - previous.y) ** 2 +
        (z - previous.z) ** 2
      )
      const threshold = event.acceleration ? SHAKE_ACCELERATION_THRESHOLD : SHAKE_ACCELERATION_WITH_GRAVITY_THRESHOLD
      const now = event.timeStamp || Date.now()

      if (magnitude > threshold && delta > SHAKE_DELTA_THRESHOLD) {
        consecutiveRef.current++
        if (consecutiveRef.current >= CONSECUTIVE_FRAMES_NEEDED) {
          consecutiveRef.current = 0
          if (now - lastShakeAtRef.current >= SHAKE_COOLDOWN_MS) {
            lastShakeAtRef.current = now
            onShakeRef.current()
          }
        }
      } else {
        consecutiveRef.current = 0
      }
    }

    const DME = DeviceMotionEvent as DeviceMotionEventWithPermission

    if (typeof DME.requestPermission === "function") {
      // iOS 13+: DeviceMotionEvent requires an explicit user-gesture permission grant.
      // Request on the first user click to avoid prompting on page load.
      const persistedPermission = readPersistedMotionPermission()
      if (persistedPermission === "granted") {
        window.addEventListener("devicemotion", handleMotion)
        return () => window.removeEventListener("devicemotion", handleMotion)
      }
      if (persistedPermission === "denied" || persistedPermission === "unavailable") {
        return
      }

      let requested = false

      async function requestOnClick() {
        if (requested) return
        requested = true
        document.removeEventListener("click", requestOnClick, true)
        try {
          const permission = await DME.requestPermission!()
          if (permission === "granted") {
            persistMotionPermission("granted")
            window.addEventListener("devicemotion", handleMotion)
          } else if (permission === "denied") {
            persistMotionPermission("denied")
          }
        } catch {
          persistMotionPermission("unavailable")
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
