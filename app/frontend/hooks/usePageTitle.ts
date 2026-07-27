import { useEffect } from "react"

export function usePageTitle(title: string | null | undefined) {
  useEffect(() => {
    const previous = document.title
    document.title = title ? `${title} | Syrus` : "Syrus"
    return () => {
      document.title = previous
    }
  }, [title])
}
