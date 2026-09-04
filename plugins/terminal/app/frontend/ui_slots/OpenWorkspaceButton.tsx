import { useState } from "react"
import { useNavigate } from "react-router-dom"
import { Button } from "@app/components/Button"
import { useT } from "@app/hooks/useT"
import { createTerminalSession } from "../api/terminal"

type Workflow = { id: number; slug?: string | null }

// Rendered into the job page's `job.workflow.actions` slot, once per workflow
// card. This used to be a hardcoded button in core's WorkflowGraph, gated on a
// feature flag.
export default function OpenWorkspaceButton({ prefix, workflow }: { prefix?: string; workflow?: Workflow }) {
  const { t } = useT("jobs")
  const navigate = useNavigate()
  const [opening, setOpening] = useState(false)

  if (!workflow) return null

  async function open() {
    if (!workflow) return
    setOpening(true)
    try {
      const { session } = await createTerminalSession({
        workflow_id: workflow.id,
        name: `${workflow.slug || `WF-${workflow.id}`} workspace`
      })
      navigate(`${prefix ?? ""}/terminal?session=${session.id}`)
    } finally {
      setOpening(false)
    }
  }

  return (
    <Button disabled={opening} onClick={open} variant="secondary">
      {t("open_terminal_in_workspace")}
    </Button>
  )
}
