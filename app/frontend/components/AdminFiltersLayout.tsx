import type { ReactNode } from "react"
import { useEffect, useState } from "react"

export function AdminFiltersLayout({ children, filterBar, smartFolders }: { children: ReactNode; filterBar?: ReactNode; smartFolders?: ReactNode }) {
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)
  const hasControls = Boolean(filterBar || smartFolders)

  if (!hasControls) {
    return <div className="space-y-3">{children}</div>
  }

  if (isDesktop) {
    if (smartFolders) {
      return (
        <div className="grid gap-5 lg:grid-cols-[16rem_minmax(0,1fr)]">
          {smartFolders}
          <div className="min-w-0 space-y-3">
            {filterBar}
            {children}
          </div>
        </div>
      )
    }

    return (
      <div className="space-y-3">
        {filterBar}
        {children}
      </div>
    )
  }

  return (
    <div className="space-y-3">
      <details className="group rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <summary className="flex cursor-pointer list-none items-center justify-between gap-3 px-4 py-3 text-sm font-medium text-gray-700 dark:text-gray-200">
          <span>Folders and filters</span>
          <span className="text-gray-400 dark:text-gray-500 group-open:hidden">Show</span>
          <span className="hidden text-gray-400 dark:text-gray-500 group-open:inline">Hide</span>
        </summary>
        <div className="space-y-4 border-t border-gray-200 dark:border-gray-700 p-4">
          {filterBar}
          {smartFolders}
        </div>
      </details>
      {children}
    </div>
  )
}

function useMediaQuery(query: string, defaultMatches: boolean) {
  const [matches, setMatches] = useState(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return defaultMatches

    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    const updateMatches = () => setMatches(media.matches)
    updateMatches()

    if (typeof media.addEventListener === "function") {
      media.addEventListener("change", updateMatches)
      return () => media.removeEventListener("change", updateMatches)
    }

    media.addListener(updateMatches)
    return () => media.removeListener(updateMatches)
  }, [query])

  return matches
}
