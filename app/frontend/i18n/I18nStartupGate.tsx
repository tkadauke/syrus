import { useEffect, useState, type ReactNode } from "react"
import { i18nReady } from "."

export function I18nStartupGate({ children, ready = i18nReady }: { children: ReactNode; ready?: Promise<unknown> }) {
  const [localeReady, setLocaleReady] = useState(false)

  useEffect(() => {
    let mounted = true
    void ready.then(() => {
      if (mounted) setLocaleReady(true)
    })
    return () => {
      mounted = false
    }
  }, [ready])

  if (!localeReady) return <div className="min-h-screen bg-surface-inset" aria-busy="true" />
  return children
}
