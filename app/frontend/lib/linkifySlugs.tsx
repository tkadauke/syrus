import type { ReactNode } from "react"
import { Link } from "react-router-dom"
import { CopyableSlug } from "../components/CopyableSlug"
import { SlugHoverCard } from "../components/SlugHoverCard"

const slugPattern = /([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)/
const slugLinkClassName = "text-brand hover:underline dark:text-brand-emphasis"

type LinkifySlugOptions = {
  hoverCards?: boolean
  jobStyle?: "link" | "copyable"
  slugStyle?: "link" | "copyable"
}

export function linkifySlugs(text: string, options: LinkifySlugOptions = {}): ReactNode[] {
  const hoverCards = options.hoverCards ?? true
  const slugStyle = options.slugStyle ?? "link"

  return text.split(slugPattern).map((part, index) => {
    const job = part.match(/^JOB-(\d+)$/)
    if (job) {
      if ((options.jobStyle === "copyable" || slugStyle === "copyable") && !hoverCards) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
      }

      return (
        <SlugHoverCard key={index} kind="job" id={Number(job[1])}>
          {options.jobStyle === "copyable" || slugStyle === "copyable" ? (
            <CopyableSlug className="text-xs normal-case" slug={part} />
          ) : (
            <Link className={slugLinkClassName} to={`/jobs/${job[1]}`}>
              {part}
            </Link>
          )}
        </SlugHoverCard>
      )
    }

    const epic = part.match(/^EPIC-(\d+)$/)
    if (epic) {
      if (slugStyle === "copyable" && !hoverCards) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
      }

      return (
        <SlugHoverCard key={index} kind="epic" id={Number(epic[1])}>
          {slugStyle === "copyable" ? (
            <CopyableSlug className="text-xs normal-case" slug={part} />
          ) : (
            <Link className={slugLinkClassName} to={`/epics/${epic[1]}`}>
              {part}
            </Link>
          )}
        </SlugHoverCard>
      )
    }

    const doc = part.match(/^(DOC)-(\d+)$/)
    if (doc) {
      if (slugStyle === "copyable" && !hoverCards) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
      }

      return (
        <SlugHoverCard key={index} kind="plugin" prefix={doc[1]} id={Number(doc[2])}>
          {slugStyle === "copyable" ? (
            <CopyableSlug className="text-xs normal-case" slug={part} />
          ) : (
            <Link className={slugLinkClassName} to={`/design_docs/${doc[2]}`}>
              {part}
            </Link>
          )}
        </SlugHoverCard>
      )
    }

    const chat = part.match(/^CHAT-(\d+)$/)
    if (chat) {
      if (slugStyle === "copyable" && !hoverCards) {
        return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
      }

      return (
        <SlugHoverCard key={index} kind="chat" id={Number(chat[1])}>
          <CopyableSlug className="text-xs normal-case" slug={part} />
        </SlugHoverCard>
      )
    }

    if (slugStyle === "copyable" && /^([A-Z]{2,}(?:_[A-Z0-9]+)*-\d+)$/.test(part)) {
      return <CopyableSlug className="text-xs normal-case" key={index} slug={part} />
    }

    return part
  })
}

export function containsSlug(text: string) {
  return /[A-Z]{2,}(?:_[A-Z0-9]+)*-\d+/.test(text)
}
