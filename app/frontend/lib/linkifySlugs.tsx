import type { ReactNode } from "react"
import { Link } from "react-router-dom"

const slugPattern = /((?:JOB|EPIC)-\d+)/

export function linkifySlugs(text: string): ReactNode[] {
  return text.split(slugPattern).map((part, index) => {
    const job = part.match(/^JOB-(\d+)$/)
    if (job) {
      return (
        <Link className="text-blue-600 hover:underline dark:text-blue-400" key={index} to={`/jobs/${job[1]}`}>
          {part}
        </Link>
      )
    }

    const epic = part.match(/^EPIC-(\d+)$/)
    if (epic) {
      return (
        <Link className="text-blue-600 hover:underline dark:text-blue-400" key={index} to={`/epics/${epic[1]}`}>
          {part}
        </Link>
      )
    }

    return part
  })
}

export function containsSlug(text: string) {
  return /(?:JOB|EPIC)-\d+/.test(text)
}
