import { useCallback, useEffect, useRef, useState } from "react"

// Shared "write to clipboard, flip a boolean, clear it after a delay" pattern
// used by every copy-to-clipboard control in the app (job slugs, PR links,
// local-daemon pairing command, chat message text).
export function useCopyToClipboard(resetDelayMs = 1500) {
  const [copied, setCopied] = useState(false)
  const timeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => () => {
    if (timeoutRef.current) clearTimeout(timeoutRef.current)
  }, [])

  const copy = useCallback((text: string) => {
    if (!navigator.clipboard?.writeText) return

    void navigator.clipboard.writeText(text).then(() => {
      setCopied(true)
      if (timeoutRef.current) clearTimeout(timeoutRef.current)
      timeoutRef.current = setTimeout(() => setCopied(false), resetDelayMs)
    }, () => setCopied(false))
  }, [resetDelayMs])

  return { copied, copy }
}
