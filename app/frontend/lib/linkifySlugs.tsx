import type { ReactNode } from "react"
import { Link } from "react-router-dom"
import { CopyableSlug } from "../components/CopyableSlug"
import { SlugHoverCard } from "../components/SlugHoverCard"

const slugPattern = /((?:JOB|EPIC|DOC|CHAT)-\d+)/
const slugLinkClassName = "text-brand hover:underline dark:text-brand-emphasis"

type LinkifySlugOptions = {
  jobStyle?: "link" | "copyable"
}

export function linkifySlugs(text: string, options: LinkifySlugOptions = {}): ReactNode[] {
  return text.split(slugPattern).map((part, index) => {
    const job = part.match(/^JOB-(\d+)$/)
    if (job) {
      return (
        <SlugHoverCard key={index} kind="job" id={Number(job[1])}>
          {options.jobStyle === "copyable" ? (
            <CopyableSlug className="text-xs" slug={part} />
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
      return (
        <SlugHoverCard key={index} kind="epic" id={Number(epic[1])}>

          <Link className={slugLinkClassName} to={`/epics/${epic[1]}`}>
            {part}
          </Link>
        </SlugHoverCard>
      )
    }

    const doc = part.match(/^(DOC)-(\d+)$/)
    if (doc) {
      return (
        <SlugHoverCard key={index} kind="plugin" prefix={doc[1]} id={Number(doc[2])}>
          <Link className={slugLinkClassName} to={`/design_docs/${doc[2]}`}>
            {part}
          </Link>
        </SlugHoverCard>
      )
    }

    const chat = part.match(/^CHAT-(\d+)$/)
    if (chat) {
      return (
        <SlugHoverCard key={index} kind="chat" id={Number(chat[1])}>
          <CopyableSlug className="text-xs" slug={part} />
        </SlugHoverCard>
      )
    }

    return part
  })
}

export function containsSlug(text: string) {
  return /(?:JOB|EPIC|DOC|CHAT)-\d+/.test(text)
}
