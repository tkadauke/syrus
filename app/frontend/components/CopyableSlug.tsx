import { useT } from "../hooks/useT"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"

type CopyableSlugTone = "default" | "inverted"

const copyableSlugToneClasses: Record<CopyableSlugTone, { button: string; icon: string; iconCopied: string }> = {
  default: {
    button: "text-gray-600 hover:bg-gray-100 hover:text-gray-900 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-gray-100",
    icon: "text-gray-400 group-hover:text-gray-600 dark:text-gray-500 dark:group-hover:text-gray-300",
    iconCopied: "text-green-600 dark:text-green-300"
  },
  inverted: {
    button: "text-on-brand hover:bg-white/10 hover:text-on-brand dark:text-on-brand dark:hover:bg-white/10 dark:hover:text-on-brand",
    icon: "text-on-brand/80 group-hover:text-on-brand",
    iconCopied: "text-on-brand"
  }
}

export function CopyableSlug({ slug, className = "", tone = "default" }: { slug: string; className?: string; tone?: CopyableSlugTone }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  const toneClasses = copyableSlugToneClasses[tone]

  return (
    <button
      aria-label={t("copy.copy_to_clipboard", { slug })}
      className={`group inline-flex max-w-full min-w-0 items-center gap-1 rounded px-1 py-0.5 font-mono focus:outline-none focus:ring-2 focus:ring-brand ${toneClasses.button} ${className}`}
      data-slug-copy-button
      onClick={() => copy(slug)}
      title={copied ? t("copy.copied") : t("copy.copy", { slug })}
      type="button"
    >
      <span className="min-w-0 break-all text-left">{slug}</span>
      <CopyIcon
        className={`h-3.5 w-3.5 shrink-0 ${copied ? toneClasses.iconCopied : toneClasses.icon}`}
      />
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
