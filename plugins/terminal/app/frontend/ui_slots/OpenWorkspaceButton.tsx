import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { Button } from "@app/components/Button"
import { useT } from "@app/hooks/useT"
import { errorMessage } from "@app/lib/errorMessage"
import { createTerminalSession } from "../api/terminal"

type Workflow = { id: number; slug?: string | null }
type WorkspaceAvailability = {
  available?: boolean
  reason?: string | null
}

// Rendered into the job page's `job.workflow.actions` slot, once per workflow
// card. This used to be a hardcoded button in core's WorkflowGraph, gated on a
// feature flag.
export default function OpenWorkspaceButton({
  availability_by_workflow_id,
  prefix,
  workflow
}: {
  availability_by_workflow_id?: Record<string, WorkspaceAvailability>
  prefix?: string
  workflow?: Workflow
}) {
  const { t } = useT("terminal")
  const navigate = useNavigate()
  const [opening, setOpening] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!workflow) return null
  const availability = availability_by_workflow_id?.[String(workflow.id)]
  if (availability?.available === false) return null

  async function open() {
    if (!workflow) return
    setError(null)
    setOpening(true)
    try {
      const { session } = await createTerminalSession({
        workflow_id: workflow.id,
        name: `${workflow.slug || `WF-${workflow.id}`} workspace`
      })
      navigate(`${prefix ?? ""}/terminal?session=${session.id}`)
    } catch (err) {
      setError(errorMessage(err, t("terminal_workspace_open_failed")))
    } finally {
      setOpening(false)
    }
  }

  return (
    <div className="flex max-w-80 flex-col items-start gap-1">
      <Button disabled={opening} onClick={open} variant="secondary">
        {t("open_terminal_in_workspace")}
      </Button>
      {error ? <p className="text-xs text-red-600 dark:text-red-300">{error}</p> : null}
    </div>
  )
}
