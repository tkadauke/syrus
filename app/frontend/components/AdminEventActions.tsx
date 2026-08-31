import { useState } from "react"
import { fileEventJob, type EventAction } from "../api/eventActions"
import { errorMessage } from "../lib/errorMessage"
import { Button } from "./Button"

type Props = {
  actions?: EventAction[] | null
  eventId: number
  eventType: string
  showDetailsLabel: string
  onToggleDetails: () => void
}

export function AdminEventActions({ actions, eventId, eventType, onToggleDetails, showDetailsLabel }: Props) {
  const [filing, setFiling] = useState(false)
  const [filedJobId, setFiledJobId] = useState<number | null>(null)
  const [filedIssueUrl, setFiledIssueUrl] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function runAction(action: EventAction) {
    if (action.id !== "file_job") return

    setFiling(true)
    setError(null)
    try {
      const result = await fileEventJob({ event_type: action.event_type || eventType, event_id: eventId })
      setFiledJobId(result.job_id ?? null)
      setFiledIssueUrl(result.issue_url ?? null)
    } catch (e) {
      setError(errorMessage(e, "Action failed."))
    } finally {
      setFiling(false)
    }
  }

  return (
    <div className="flex flex-col items-start gap-2">
      <Button onClick={onToggleDetails} size="sm" variant="secondary">
        {showDetailsLabel}
      </Button>
      {(actions || []).map((action) => (
        <button
          className="rounded border border-brand/30 px-2.5 py-1 text-xs font-medium text-brand-emphasis hover:bg-brand/10 disabled:cursor-not-allowed disabled:opacity-60 dark:border-brand/40 dark:text-brand-emphasis dark:hover:bg-brand/10"
          disabled={filing || Boolean(filedJobId || filedIssueUrl)}
          key={action.id}
          onClick={() => void runAction(action)}
          type="button"
        >
          {filing && action.id === "file_job" ? "Filing..." : action.label}
        </button>
      ))}
      {filedJobId != null ? <a className="text-xs text-gray-600 underline dark:text-gray-300" href={`/jobs/${filedJobId}`}>JOB-{filedJobId}</a> : null}
      {filedIssueUrl ? <a className="text-xs text-gray-600 underline dark:text-gray-300" href={filedIssueUrl}>Issue filed</a> : null}
      {error ? <div className="text-xs text-red-600 dark:text-red-400">{error}</div> : null}
    </div>
  )
}
