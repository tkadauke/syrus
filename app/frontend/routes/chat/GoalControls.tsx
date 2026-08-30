import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { patchChatGoal, pauseChatGoal, resumeChatGoal, stopChatGoal, type ChatGoal, type ChatGoalInput, type ChatMode, type ChatPayload } from "../../api/chats"
import { Button } from "../../components/Button"
import { CloseIcon } from "../../components/CloseIcon"
import { Input } from "../../components/Input"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { updateRecentChatCache } from "../../lib/chatCache"
import type { ChatQueryKey } from "./constants"
import { PencilIcon } from "./icons"
import { isAgentActive } from "./messageDisplay"

type GoalAction = "pause" | "resume" | "stop"

export function GoalControls({ payload, queryKey, onNotice }: { payload: ChatPayload; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const serverGoal = payload.active_goal || payload.chat.active_goal || null
  const [recentTerminalGoal, setRecentTerminalGoal] = useState<ChatGoal | null>(null)
  const goal = serverGoal || recentTerminalGoal
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [editorOpen, setEditorOpen] = useState(false)
  const agentActive = isAgentActive(payload)

  useEffect(() => {
    if (serverGoal) setRecentTerminalGoal(null)
  }, [serverGoal])

  const action = useMutation({
    mutationFn: (kind: GoalAction) => {
      if (!goal) throw new Error(t("goal_missing"))
      if (kind === "pause") return pauseChatGoal(payload.chat.id)
      if (kind === "resume") return resumeChatGoal(payload.chat.id)
      return stopChatGoal(payload.chat.id)
    },
    onSuccess: (updated, kind) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, updated.chat)
      const updatedGoal = updated.active_goal || updated.chat.active_goal || null
      if (kind === "stop" && !updatedGoal && serverGoal) {
        setRecentTerminalGoal({ ...serverGoal, status: "cancelled", terminal_reason: "operator_stopped", terminal_at: new Date().toISOString() })
      } else {
        setRecentTerminalGoal(null)
      }
      onNotice(t(kind === "pause" ? "goal_paused_notice" : kind === "resume" ? "goal_resumed_notice" : "goal_stopped_notice"))
    },
    onError: (error) => onNotice(errorMessage(error, t("goal_action_error")))
  })

  if (!goal) return null

  const status = goal.status
  const canPause = status === "active"
  const canResume = status === "paused"
  const terminal = status === "completed" || status === "blocked" || status === "cancelled"
  const disabledReason = agentActive ? t("goal_action_disabled_agent_active") : undefined
  const controlsDisabled = agentActive || action.isPending

  return (
    <>
      <section aria-label={t("goal_active_region")} className="rounded border border-gray-200 bg-gray-50 p-3 text-sm dark:border-gray-700 dark:bg-gray-900" data-testid="active-goal-strip">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <span className="rounded bg-brand/10 px-2 py-0.5 text-xs font-semibold text-brand">{t("goal_label")}</span>
              <span className={`rounded px-2 py-0.5 text-xs font-medium ${goalStatusClass(status)}`}>{goalStatusLabel(status, t)}</span>
              <span className="text-xs text-gray-500 dark:text-gray-400">{goalModeLabel(goal, payload.chat.mode, t)}</span>
              <span className="text-xs text-gray-500 dark:text-gray-400">{goalPolicySummary(goal, payload.chat.mode, t)}</span>
            </div>
            <p className="mt-1 break-words font-medium text-gray-900 dark:text-gray-100">{goal.prompt}</p>
            {goal.completion_condition ? <p className="mt-1 break-words text-xs text-gray-600 dark:text-gray-300">{t("goal_completion_prefix")} {goal.completion_condition}</p> : null}
            {terminal && goal.terminal_reason ? <p className="mt-1 break-words text-xs text-gray-600 dark:text-gray-300">{goal.terminal_reason}</p> : null}
          </div>
          <div className="flex shrink-0 items-center gap-1">
            <GoalIconButton ariaLabel={t("goal_edit")} disabled={controlsDisabled || terminal} title={disabledReason || t("goal_edit")} onClick={() => setEditorOpen(true)}>
              <PencilIcon className="h-4 w-4" />
            </GoalIconButton>
            <GoalIconButton ariaLabel={t("goal_pause")} disabled={controlsDisabled || !canPause} title={disabledReason || t("goal_pause")} onClick={() => action.mutate("pause")}>
              <PauseIcon />
            </GoalIconButton>
            <GoalIconButton ariaLabel={t("goal_resume")} disabled={controlsDisabled || !canResume} title={disabledReason || t("goal_resume")} onClick={() => action.mutate("resume")}>
              <PlayIcon />
            </GoalIconButton>
            <GoalIconButton ariaLabel={t("goal_stop")} disabled={controlsDisabled || terminal} title={disabledReason || t("goal_stop")} onClick={() => action.mutate("stop")}>
              <StopSquareIcon />
            </GoalIconButton>
          </div>
        </div>
        {agentActive ? <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">{t("goal_controls_agent_active")}</p> : null}
      </section>
      {editorOpen ? <GoalEditModal goal={goal} mode={payload.chat.mode} chatId={payload.chat.id} queryKey={queryKey} onClose={() => setEditorOpen(false)} onNotice={onNotice} /> : null}
    </>
  )
}

function GoalEditModal({ chatId, goal, mode, queryKey, onClose, onNotice }: { chatId: string | number; goal: ChatGoal; mode?: ChatMode | null; queryKey: ChatQueryKey; onClose: () => void; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [prompt, setPrompt] = useState(goal.prompt)
  const [completionCondition, setCompletionCondition] = useState(goal.completion_condition || "")
  const [approvalPolicy, setApprovalPolicy] = useState<ChatGoal["approval_policy"]>(goal.approval_policy)
  const [autoFileProposals, setAutoFileProposals] = useState(goal.auto_file_proposals)
  const [autoSubmitJobs, setAutoSubmitJobs] = useState(goal.auto_submit_jobs)
  const effectiveMode = goalMode(goal, mode)
  const planningMode = effectiveMode === "planning"
  const codingMode = effectiveMode === "coding" || effectiveMode === "local"
  const save = useMutation({
    mutationFn: () => {
      const input: ChatGoalInput = {
        prompt: prompt.trim(),
        completion_condition: completionCondition.trim() || null,
        approval_policy: approvalPolicy,
        auto_file_proposals: planningMode ? autoFileProposals : false,
        auto_submit_jobs: codingMode ? autoSubmitJobs : false
      }
      return patchChatGoal(chatId, input)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      updateRecentChatCache(queryClient, updated.chat)
      onNotice(t("goal_updated_notice"))
      onClose()
    },
    onError: (error) => onNotice(errorMessage(error, t("goal_update_error")))
  })

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key !== "Escape") return
      event.preventDefault()
      onClose()
    }

    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (prompt.trim().length === 0 || save.isPending) return
    save.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-3 py-6" role="presentation">
      <section aria-labelledby="goal-edit-title" aria-modal="true" className="max-h-full w-full max-w-2xl overflow-y-auto rounded border border-gray-200 bg-white shadow-xl dark:border-gray-700 dark:bg-gray-950" role="dialog">
        <form onSubmit={submit}>
          <header className="flex items-center justify-between border-b border-gray-200 px-5 py-4 dark:border-gray-800">
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="goal-edit-title">{t("goal_edit_title")}</h2>
            <button aria-label={t("goal_close_editor")} className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button">
              <CloseIcon className="h-4 w-4" />
            </button>
          </header>
          <div className="space-y-5 px-5 py-4">
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
              {t("goal_prompt_label")}
              <textarea
                className="mt-1 min-h-28 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-brand focus:outline-none focus:ring-1 focus:ring-brand dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                onChange={(event) => setPrompt(event.target.value)}
                required
                value={prompt}
              />
            </label>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
              {t("goal_completion_label")}
              <Input className="mt-1" onChange={(event) => setCompletionCondition(event.target.value)} type="text" value={completionCondition} />
            </label>
            <fieldset className="space-y-2">
              <legend className="text-sm font-medium text-gray-700 dark:text-gray-200">{t("goal_proposal_policy_label")}</legend>
              <GoalRadio checked={approvalPolicy === "manual"} label={t("goal_policy_manual")} name="approval-policy" onChange={() => setApprovalPolicy("manual")} />
              <GoalRadio checked={approvalPolicy === "auto"} label={t("goal_policy_auto")} name="approval-policy" onChange={() => setApprovalPolicy("auto")} />
            </fieldset>
            {planningMode ? (
              <fieldset className="space-y-2">
                <legend className="text-sm font-medium text-gray-700 dark:text-gray-200">{t("goal_planning_automation_label")}</legend>
                <GoalRadio checked={!autoFileProposals} label={t("goal_planning_draft_only")} name="planning-automation" onChange={() => setAutoFileProposals(false)} />
                <GoalRadio checked={autoFileProposals} label={t("goal_planning_auto_file")} name="planning-automation" onChange={() => setAutoFileProposals(true)} />
              </fieldset>
            ) : null}
            {codingMode ? (
              <fieldset className="space-y-2">
                <legend className="text-sm font-medium text-gray-700 dark:text-gray-200">{t("goal_coding_automation_label")}</legend>
                <GoalRadio checked={!autoSubmitJobs} label={t("goal_coding_draft_only")} name="coding-automation" onChange={() => setAutoSubmitJobs(false)} />
                <GoalRadio checked={autoSubmitJobs} label={t("goal_coding_auto_submit")} name="coding-automation" onChange={() => setAutoSubmitJobs(true)} />
              </fieldset>
            ) : null}
          </div>
          <footer className="flex justify-end gap-2 border-t border-gray-200 px-5 py-4 dark:border-gray-800">
            <Button disabled={save.isPending} onClick={onClose} type="button" variant="secondary">{t("cancel")}</Button>
            <Button disabled={save.isPending || prompt.trim().length === 0} type="submit">{t("save")}</Button>
          </footer>
        </form>
      </section>
    </div>
  )
}

function GoalRadio({ checked, label, name, onChange }: { checked: boolean; label: string; name: string; onChange: () => void }) {
  return (
    <label className="flex items-start gap-2 rounded border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200">
      <Input checked={checked} className="mt-1 h-4 w-4 accent-brand" fullWidth={false} name={name} onChange={onChange} type="radio" />
      <span>{label}</span>
    </label>
  )
}

function GoalIconButton({ ariaLabel, children, disabled, onClick, title }: { ariaLabel: string; children: ReactNode; disabled: boolean; onClick: () => void; title: string }) {
  return (
    <button
      aria-label={ariaLabel}
      className="inline-flex h-8 w-8 items-center justify-center rounded border border-gray-200 bg-white text-gray-600 hover:border-brand/30 hover:bg-brand/10 hover:text-brand disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-300"
      disabled={disabled}
      onClick={onClick}
      title={title}
      type="button"
    >
      {children}
    </button>
  )
}

function goalMode(goal: ChatGoal, fallback?: ChatMode | null) {
  const mode = typeof goal.mode_snapshot?.mode === "string" ? goal.mode_snapshot.mode : fallback
  return mode === "coding" || mode === "local" ? mode : "planning"
}

function goalModeLabel(goal: ChatGoal, fallback: ChatMode | null | undefined, t: (key: string, options?: Record<string, unknown>) => string) {
  const mode = goalMode(goal, fallback)
  if (mode === "coding") return t("goal_mode_coding")
  if (mode === "local") return t("goal_mode_local")
  return t("goal_mode_planning")
}

function goalPolicySummary(goal: ChatGoal, fallback: ChatMode | null | undefined, t: (key: string, options?: Record<string, unknown>) => string) {
  const mode = goalMode(goal, fallback)
  if (mode === "planning") return goal.auto_file_proposals ? t("goal_policy_summary_auto_file") : t("goal_policy_summary_draft")
  return goal.auto_submit_jobs ? t("goal_policy_summary_auto_submit") : t("goal_policy_summary_draft")
}

function goalStatusLabel(status: ChatGoal["status"], t: (key: string, options?: Record<string, unknown>) => string) {
  if (status === "active") return t("goal_status_active")
  if (status === "paused") return t("goal_status_paused")
  if (status === "completed") return t("goal_status_completed")
  if (status === "blocked") return t("goal_status_blocked")
  return t("goal_status_stopped")
}

function goalStatusClass(status: ChatGoal["status"]) {
  if (status === "active") return "bg-green-50 text-green-700 dark:bg-green-950 dark:text-green-200"
  if (status === "paused") return "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-200"
  if (status === "blocked") return "bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-200"
  return "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"
}

function PauseIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M8 5v14" />
      <path d="M16 5v14" />
    </svg>
  )
}

function PlayIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
      <path d="M8 5v14l11-7Z" />
    </svg>
  )
}

function StopSquareIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="currentColor" viewBox="0 0 24 24">
      <path d="M6 6h12v12H6Z" />
    </svg>
  )
}
