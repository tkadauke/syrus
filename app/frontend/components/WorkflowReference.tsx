import type { MouseEvent } from "react"
import { Link } from "react-router-dom"
import { useT } from "../hooks/useT"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { CopyIcon } from "./CopyableSlug"

export function WorkflowReference({ slug, path, className = "" }: { slug: string; path: string; className?: string }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  const handleCopy = (event: MouseEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.stopPropagation()
    copy(slug)
  }

  return (
    <span className={`inline-flex items-center gap-1 rounded px-1 py-0.5 font-mono text-xs ${className}`}>
      <Link className="text-brand hover:underline" onClick={(event) => event.stopPropagation()} to={path}>{slug}</Link>
      <button aria-label={t("copy.copy_to_clipboard", { slug })} className="rounded p-0.5 text-text-secondary hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand" data-slug-copy-button onClick={handleCopy} title={copied ? t("copy.copied") : t("copy.copy", { slug })} type="button">
        <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-success-text" : ""}`} />
      </button>
    </span>
  )
}
