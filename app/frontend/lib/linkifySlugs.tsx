import type { MouseEvent, ReactNode } from "react"
import { Link } from "react-router-dom"
import { CopyIcon, CopyableSlug } from "../components/CopyableSlug"
import { SlugReferenceCard } from "../components/SlugHoverCard"
import { useT } from "../hooks/useT"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { hrefForSlugReference, slugReferenceRegistryEntryForPrefix, type SlugReferenceRegistryEntry } from "./slugReferenceRegistry"

const slugPattern = /([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)/
const linkedSlugClassName = "inline-flex max-w-full min-w-0 items-center gap-1 rounded px-1 py-0.5 font-mono text-xs normal-case"
const slugLinkToneClassNames = {
  default: "text-brand hover:underline dark:text-brand-emphasis",
  inverted: "text-on-brand underline hover:no-underline dark:text-on-brand"
}
const linkedSlugToneClassNames = {
  default: "text-text-primary hover:bg-surface-raised",
  inverted: "text-on-brand hover:bg-white/10 dark:text-on-brand dark:hover:bg-white/10"
}
const linkedSlugCopyButtonToneClassNames = {
  default: "text-text-secondary hover:text-text-primary",
  inverted: "text-on-brand/80 hover:text-on-brand"
}

type SlugTone = "default" | "inverted"

type LinkifySlugOptions = {
  hoverCards?: boolean
  jobStyle?: "link" | "copyable"
  slugStyle?: "link" | "copyable"
  tone?: SlugTone
}

export function linkifySlugs(text: string, options: LinkifySlugOptions = {}): ReactNode[] {
  const hoverCards = options.hoverCards ?? true
  const slugStyle = options.slugStyle ?? "link"
  const tone = options.tone ?? "default"

  return text.split(slugPattern).map((part, index) => {
    const reference = parseSlugReference(part)
    if (!reference) {
      if (slugStyle === "copyable" && /^([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)$/.test(part)) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} tone={tone} />
      }

      return part
    }

    const { entry, id, slug } = reference
    const copyOnly = slugStyle === "copyable" || (entry.type === "job" && options.jobStyle === "copyable")

    if (!entry.linkifiesGeneratedText && !(copyOnly && entry.copyable)) return part

    const control = <SlugReferenceControl copyOnly={copyOnly} entry={entry} id={id} slug={slug} tone={tone} />
    if (!hoverCards || (!entry.previewAvailable && !entry.copyable && !hrefForSlugReference(entry, id))) return <span key={index}>{control}</span>

    return (
      <SlugReferenceCard entry={entry} id={id} key={index} slug={slug}>
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

function SlugReferenceControl({ copyOnly, entry, id, slug, tone }: { copyOnly: boolean; entry: SlugReferenceRegistryEntry; id: number; slug: string; tone: SlugTone }) {
  const href = hrefForSlugReference(entry, id)

  if (copyOnly && entry.copyable) return <CopyableSlug className="text-xs normal-case" slug={slug} tone={tone} />
  if (href && entry.copyable) return <LinkedCopyableSlug href={href} slug={slug} tone={tone} />
  if (href)
    return (
      <Link className={slugLinkToneClassNames[tone]} to={href}>
        {slug}
      </Link>
    )
  if (entry.copyable) return <CopyableSlug className="text-xs normal-case" slug={slug} tone={tone} />

  return <span className="font-mono text-text-secondary">{slug}</span>
}

function LinkedCopyableSlug({ href, slug, tone }: { href: string; slug: string; tone: SlugTone }) {
  const { t } = useT("common")
  const { copied, copy } = useCopyToClipboard()
  const linkClassName = `${slugLinkToneClassNames[tone]} min-w-0 break-all`

  const handleCopy = (event: MouseEvent<HTMLButtonElement>) => {
    event.preventDefault()
    event.stopPropagation()
    copy(slug)
  }

  return (
    <span className={`${linkedSlugClassName} ${linkedSlugToneClassNames[tone]}`}>
      {href.startsWith("/s/") ? (
        <a className={linkClassName} href={href}>
          {slug}
        </a>
      ) : (
        <Link className={linkClassName} to={href}>
          {slug}
        </Link>
      )}
      <button
        aria-label={t("copy.copy_to_clipboard", { slug })}
        className={`group shrink-0 rounded p-0.5 focus:outline-none focus:ring-2 focus:ring-brand ${linkedSlugCopyButtonToneClassNames[tone]}`}
        data-slug-copy-button
        onClick={handleCopy}
        title={copied ? t("copy.copied") : t("copy.copy", { slug })}
        type="button"
      >
        <CopyIcon className={`h-3.5 w-3.5 ${copied ? (tone === "inverted" ? "text-on-brand" : "text-success-text") : (tone === "inverted" ? "group-hover:text-on-brand" : "group-hover:text-text-primary")}`} />
      </button>
    </span>
  )
}
