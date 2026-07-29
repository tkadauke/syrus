import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useNavigate } from "react-router-dom"
import { deleteJobCommand, patchJobCommand, postJobCommand } from "../../api/jobs"
import { buttonClass, type ButtonTone } from "../../lib/buttonClasses"
import { useConfirm } from "../../hooks/useConfirm"
import type { JobDetailQueryKey, JobWorkflowsQueryKey } from "./queryKeys"

// Shared Job-command spine extracted from JobDetail.tsx: the mutation hook that
// POST/PATCH/DELETEs a Job command and invalidates the relevant queries, the
// CommandInput shape it accepts, and the CommandButton that fires one. Kept in a
// leaf module so both JobDetail.tsx and the workflow/step/run subcomponents can
// import it without a circular dependency back through the route file.

export type CommandInput =
  | { method: "post"; path: string; body?: unknown; confirm?: string }
  | { method: "patch"; path: string; body?: unknown; confirm?: string }
  | { method: "delete"; path: string; confirm?: string }

export function useJobCommand(jobId: number, queryKey: JobDetailQueryKey, workflowsQueryKey: JobWorkflowsQueryKey | undefined, onNotice: (message: string | null) => void) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const { confirm, dialog } = useConfirm()

  const mutation = useMutation({
    mutationFn: async (input: CommandInput) => {
      if (input.confirm && !(await confirm({ message: input.confirm, destructive: true }))) return { message: null }
      if (input.method === "delete") return deleteJobCommand(input.path)
      if (input.method === "patch") return patchJobCommand(input.path, input.body)
      return postJobCommand(input.path, input.body)
    },
    onSuccess: (payload) => {
      if (payload.redirect_to) navigate(payload.redirect_to)
      onNotice(payload.message || null)
      void queryClient.invalidateQueries({ queryKey })
      if (workflowsQueryKey) void queryClient.invalidateQueries({ queryKey: workflowsQueryKey })
      void queryClient.invalidateQueries({ queryKey: ["jobs"], exact: true })
    }
  })

  return { ...mutation, dialog }
}

export type JobCommand = ReturnType<typeof useJobCommand>

export function CommandButton({ children, command, input, tone = "primary" }: { children: ReactNode; command: JobCommand; input: CommandInput; tone?: ButtonTone }) {
  return (
    <button className={buttonClass(tone)} disabled={command.isPending} onClick={() => command.mutate(input)} type="button">
      {children}
    </button>
  )
}
