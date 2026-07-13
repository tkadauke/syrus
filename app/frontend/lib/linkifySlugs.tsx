import type { ReactNode } from "react"
import { Link } from "react-router-dom"
import { SlugHoverCard } from "../components/SlugHoverCard"

const slugPattern = /((?:JOB|EPIC)-\d+)/

export function linkifySlugs(text: string): ReactNode[] {
  return text.split(slugPattern).map((part, index) => {
    const job = part.match(/^JOB-(\d+)$/)
    if (job) {
      return (
        <SlugHoverCard key={index} kind="job" id={Number(job[1])}>
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/jobs/${job[1]}`}>
            {part}
          </Link>
        </SlugHoverCard>
      )
    }

    const epic = part.match(/^EPIC-(\d+)$/)
    if (epic) {
      return (
        <SlugHoverCard key={index} kind="epic" id={Number(epic[1])}>
          <Link className="text-blue-600 hover:underline dark:text-blue-400" to={`/epics/${epic[1]}`}>
            {part}
          </Link>
        </SlugHoverCard>
      )
    }

    return part
  })
}

export function containsSlug(text: string) {
  return /(?:JOB|EPIC)-\d+/.test(text)
}
