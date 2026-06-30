import { useState } from "react"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { ChatProposal } from "../api/chats"
import { fetchBootstrap } from "../api/bootstrap"
import { startEpic } from "../api/epics"
import { ApiError } from "../api/client"

// "Start" next to a confirmed Epic proposal — moves the Epic to In Progress so
// its Jobs begin. Only shown for Epic materializations that aren't already
// running or finished.
const STARTABLE_EPIC_STATES = ["backlog", "ready"]

export function StartEpicButton({ proposal, onNotice }: { proposal: ChatProposal; onNotice: (message: string | null) => void }) {
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const currentUser = bootstrap.data?.current_user
  const statePath = proposal.materialized_epic_state_path
  const [started, setStarted] = useState(false)
  const start = useMutation({
    mutationFn: () => startEpic(statePath as string),
    onSuccess: () => {
      setStarted(true)
      onNotice("Epic moved to In Progress — its Jobs will start.")
    }
  })

  if (!statePath) return null
  const epicState = started ? "in_progress" : proposal.materialized_epic_state
  if (epicState && !STARTABLE_EPIC_STATES.includes(epicState)) {
    return <span className="text-xs font-medium text-blue-700 dark:text-blue-300">In progress</span>
  }
  if (!currentUser?.admin && currentUser?.role !== "developer") return null

  return (
    <>
      <button
        className="inline-flex items-center rounded-full bg-blue-600 px-3 py-1 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60"
        disabled={start.isPending}
        onClick={() => start.mutate()}
        type="button"
      >
        {start.isPending ? "Starting…" : "Start"}
      </button>
      {start.isError ? (
        <span className="text-xs text-red-700 dark:text-red-300">
          {start.error instanceof ApiError ? start.error.message : "Could not start the Epic."}
        </span>
      ) : null}
    </>
  )
}
