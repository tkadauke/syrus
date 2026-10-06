export const MOTION_PERMISSION_STORAGE_KEY = "syrus:shake-to-report:motion-permission"

export type PersistedMotionPermission = "granted" | "denied" | "unavailable"

export type MotionPermissionStorageState = {
  permission: PersistedMotionPermission | null
  storageAvailable: boolean
}

export function readPersistedMotionPermissionState(): MotionPermissionStorageState {
  if (typeof window === "undefined") return { permission: null, storageAvailable: false }

  try {
    const permission = window.localStorage.getItem(MOTION_PERMISSION_STORAGE_KEY)
    if (permission === "granted" || permission === "denied" || permission === "unavailable") {
      return { permission, storageAvailable: true }
    }
  } catch {
    return { permission: null, storageAvailable: false }
  }

  return { permission: null, storageAvailable: true }
}

export function readPersistedMotionPermission(): PersistedMotionPermission | null {
  return readPersistedMotionPermissionState().permission
}

export function persistMotionPermission(permission: PersistedMotionPermission) {
  try {
    window.localStorage.setItem(MOTION_PERMISSION_STORAGE_KEY, permission)
  } catch {
    // Shake-to-report should still work when persistence is unavailable.
  }
}

export function clearPersistedMotionPermission() {
  try {
    window.localStorage.removeItem(MOTION_PERMISSION_STORAGE_KEY)
    return true
  } catch {
    return false
  }
}
