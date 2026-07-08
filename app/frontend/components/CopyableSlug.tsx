import { useEffect, useState } from "react"
import { useT } from "../hooks/useT"

export function CopyableSlug({ slug, className = "" }: { slug: string; className?: string }) {
  const { t } = useT("common")
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!copied) return

    const timeout = window.setTimeout(() => setCopied(false), 1500)
    return () => window.clearTimeout(timeout)
  }, [copied])

  async function copySlug() {
    if (!navigator.clipboard?.writeText) return

    try {
      await navigator.clipboard.writeText(slug)
      setCopied(true)
    } catch {
      setCopied(false)
    }
  }

  return (
    <button
      aria-label={t("copy.copy_to_clipboard", { slug })}
      className={`group inline-flex items-center gap-1 rounded px-1 py-0.5 font-mono text-gray-600 hover:bg-gray-100 hover:text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-gray-100 ${className}`}
      onClick={copySlug}
      title={copied ? t("copy.copied") : t("copy.copy", { slug })}
      type="button"
    >
      <span>{slug}</span>
      <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-green-600 dark:text-green-300" : "text-gray-400 group-hover:text-gray-600 dark:text-gray-500 dark:group-hover:text-gray-300"}`} />
    </button>
  )
}

export function CopyIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" viewBox="0 0 20 20">
      <rect height="11" rx="2" stroke="currentColor" strokeWidth="1.8" width="11" x="6" y="3" />
      <path d="M3 7v8a2 2 0 0 0 2 2h8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}
