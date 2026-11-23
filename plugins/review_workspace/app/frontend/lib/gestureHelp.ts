import { useCallback, useState } from "react"

// Bump when the gesture copy or interaction changes enough that operators who
// dismissed the previous coach should see it again.
export const GESTURE_HELP_VERSION = 1
export const GESTURE_HELP_STORAGE_KEY = "syrus.reviewWorkspace.gestureHelpAcknowledged"

function acknowledgedVersion() {
  try {
    return Number(window.localStorage.getItem(GESTURE_HELP_STORAGE_KEY)) || 0
  } catch {
    // handled-error-expected: Browser storage may be unavailable; show the coach.
    return 0
  }
}

export function useGestureHelp() {
  const [visible, setVisible] = useState(() => acknowledgedVersion() < GESTURE_HELP_VERSION)
  const acknowledge = useCallback(() => {
    try {
      window.localStorage.setItem(GESTURE_HELP_STORAGE_KEY, String(GESTURE_HELP_VERSION))
    } catch {
      // handled-error-expected: Storage can be unavailable (private mode); the coach just hides for this session.
    }
    setVisible(false)
  }, [])
  const reopen = useCallback(() => setVisible(true), [])
  return { visible, acknowledge, reopen }
}
