import { useEffect, useState } from "react"

export function useMediaQuery(query: string, defaultMatches = false) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const update = () => setMatches(media.matches)
    update()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", update)
      return () => media.removeEventListener("change", update)
    }

    media.addListener(update)
    return () => media.removeListener(update)
  }, [query])

  return matches
}

/** The viewport width below which notifications and approvals share the full-screen Activity shell. */
export const ACTIVITY_MOBILE_QUERY = "(max-width: 767px)"
