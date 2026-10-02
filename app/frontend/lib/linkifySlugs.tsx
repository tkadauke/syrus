import type { MouseEvent, ReactNode } from "react"
import { Link } from "react-router-dom"
import { CopyIcon, CopyableSlug } from "../components/CopyableSlug"
import { SlugReferenceCard } from "../components/SlugHoverCard"
import { useT } from "../hooks/useT"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { hrefForSlugReference, slugReferenceRegistryEntryForPrefix, type SlugReferenceRegistryEntry } from "./slugReferenceRegistry"

const slugPattern = /([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)/
const slugLinkClassName = "text-brand hover:underline dark:text-brand-emphasis"
const linkedSlugClassName = "inline-flex max-w-full min-w-0 items-center gap-1 rounded px-1 py-0.5 font-mono text-xs normal-case"
const linkedSlugToneClassName = "text-text-primary hover:bg-surface-raised"
const linkedSlugCopyButtonClassName =
  "group shrink-0 rounded p-0.5 text-text-secondary hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"

type LinkifySlugOptions = {
  hoverCards?: boolean
  jobStyle?: "link" | "copyable"
  slugStyle?: "link" | "copyable"
}

export function linkifySlugs(text: string, options: LinkifySlugOptions = {}): ReactNode[] {
  const hoverCards = options.hoverCards ?? true
  const slugStyle = options.slugStyle ?? "link"

  return text.split(slugPattern).map((part, index) => {
    const reference = parseSlugReference(part)
    if (!reference) {
      if (slugStyle === "copyable" && /^([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)$/.test(part)) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
      }

      return part
    }

    const { entry, id, slug } = reference
    const copyOnly = slugStyle === "copyable" || (entry.type === "job" && options.jobStyle === "copyable")

    if (copyOnly && entry.copyable) {
      return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
    }

    if (!entry.linkifiesGeneratedText) return part

    const control = <SlugReferenceControl entry={entry} id={id} slug={slug} />
    if (!hoverCards || !entry.previewAvailable) return <span key={index}>{control}</span>

    return (
      <SlugReferenceCard entry={entry} id={id} key={index}>
        {control}
      </SlugReferenceCard>
    )
  })
}

export function containsSlug(text: string) {
  return /[A-Z]{2,}(?:_[A-Z0-9]+)*-\d+/.test(text)
}

function parseSlugReference(slug: string) {
  const match = slug.match(/^([A-Z]{2,}(?:_[A-Z0-9]+)*)-(\d+)$/)
  if (!match) return null

  const entry = slugReferenceRegistryEntryForPrefix(match[1])
  if (!entry) return null

  return { entry, id: Number(match[2]), slug }
}

function SlugReferenceControl({ entry, id, slug }: { entry: SlugReferenceRegistryEntry; id: number; slug: string }) {
  const href = hrefForSlugReference(entry, id)

  if (href && entry.copyable) return <LinkedCopyableSlug href={href} slug={slug} />
  if (href)
    return (
      <Link className={slugLinkClassName} to={href}>
        {slug}
      </Link>
    )
  if (entry.copyable) return <CopyableSlug className="text-xs normal-case" slug={slug} />

  return <span className="font-mono text-text-secondary">{slug}</span>
}

function LinkedCopyableSlug({ href, slug }: { href: string; slug: string }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()

  const handleCopy = (event: MouseEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.stopPropagation()
    copy(slug)
  }

  return (
    <span className={`${linkedSlugClassName} ${linkedSlugToneClassName}`}>
      <Link className={`${slugLinkClassName} min-w-0 break-all`} to={href}>
        {slug}
      </Link>
      <button
        aria-label={t("copy.copy_to_clipboard", { slug })}
        className={linkedSlugCopyButtonClassName}
        data-slug-copy-button
        onClick={handleCopy}
        title={copied ? t("copy.copied") : t("copy.copy", { slug })}
        type="button"
      >
        <CopyIcon className={`h-3.5 w-3.5 ${copied ? "text-success-text" : "group-hover:text-text-primary"}`} />
      </button>
    </span>
  )
}
