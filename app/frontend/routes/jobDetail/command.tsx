import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useNavigate } from "react-router-dom"
import { deleteJobCommand, patchJobCommand, postJobCommand, type JobCommandPayload, type JobDetailPayload } from "../../api/jobs"
import { buttonClass, type ButtonTone } from "../../lib/buttonClasses"
import { scheduleJobDetailInvalidation } from "../../lib/appEvents"
import { useConfirm } from "../../hooks/useConfirm"
import type { JobDetailQueryKey, JobWorkflowsQueryKey } from "./queryKeys"
import type { NoticeToastTone } from "../../components/NoticeToast"
import { errorMessage } from "../../lib/errorMessage"
import { useT } from "../../hooks/useT"

// Shared Job-command spine extracted from JobDetail.tsx: the mutation hook that
// POST/PATCH/DELETEs a Job command and invalidates the relevant queries, the
// CommandInput shape it accepts, and the CommandButton that fires one. Kept in a
// leaf module so both JobDetail.tsx and the workflow/step/run subcomponents can
// import it without a circular dependency back through the route file.

export type CommandInput =
  | { method: "post"; path: string; body?: unknown; confirm?: string }
  | { method: "patch"; path: string; body?: unknown; confirm?: string }
  | { method: "delete"; path: string; confirm?: string }

type CancelledCommand = { cancelled: true }

export function useJobCommand(jobId: number, queryKey: JobDetailQueryKey, workflowsQueryKey: JobWorkflowsQueryKey | undefined, onNotice: (message: string | null, tone?: NoticeToastTone) => void) {
  const { t } = useT("jobs")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const { confirm, dialog } = useConfirm()

  const mutation = useMutation({
    mutationFn: async (input: CommandInput): Promise<JobCommandPayload | CancelledCommand> => {
      if (input.confirm && !(await confirm({ message: input.confirm, destructive: true }))) return { cancelled: true }
      if (input.method === "delete") return deleteJobCommand(input.path)
      if (input.method === "patch") return patchJobCommand(input.path, input.body)
      return postJobCommand(input.path, input.body)
    },
    onSuccess: (payload) => {
      if ("cancelled" in payload) return
      if (payload.redirect_to) navigate(payload.redirect_to)
      onNotice(payload.message || null)
      // Apply the state/actions the command response already carries
      // synchronously, so job state and the buttons that depend on it
      // (e.g. "Approve") update together instead of the button lingering
      // for one more round trip until the invalidated query below refetches.
      // Guard on the response's job id: `restart` returns the newly created
      // replacement Job, not the one this hook/queryKey is bound to, so a
      // payload naming a different job must never be merged into this
      // Job's cache entry.
      const respondsForThisJob = payload.job === undefined || payload.job.id === jobId
      if (respondsForThisJob && (payload.job || payload.actions)) {
        queryClient.setQueryData<JobDetailPayload>(queryKey, (old) => old && {
          ...old,
          job: payload.job ? { ...old.job, ...payload.job } : old.job,
          actions: payload.actions ?? old.actions
        })
      }
      scheduleJobDetailInvalidation(queryClient, queryKey)
      if (workflowsQueryKey) scheduleJobDetailInvalidation(queryClient, workflowsQueryKey)
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
    },
    onError: (error) => {
      onNotice(errorMessage(error, t("command_error")), "error")
    }
  })

  return { ...mutation, confirm, dialog }
}

export type JobCommand = ReturnType<typeof useJobCommand>

export function CommandButton({ children, command, input, tone = "primary" }: { children: ReactNode; command: JobCommand; input: CommandInput; tone?: ButtonTone }) {
  return (
    <button className={buttonClass(tone)} disabled={command.isPending} onClick={() => command.mutate(input)} type="button">
      {children}
    </button>
  )
}
