import type { FormEvent } from "react"
import { useRef, useState } from "react"
import { useT } from "../../hooks/useT"
import { CloseIcon } from "../../components/CloseIcon"
import { buttonClass, type ButtonTone } from "../../lib/buttonClasses"
import { useDismissiblePopup } from "../../lib/useDismissiblePopup"
import { type JobDetailPayload } from "../../api/jobs"
import { errorMessage } from "../../lib/errorMessage"
import { CommandButton, useJobCommand, type CommandInput } from "./command"
import { menuButtonClass } from "./formatting"


type HeaderAction = {
  key: string
  label: string
  input: HeaderCommandInput
  tone: ButtonTone
}

type HeaderCommandInput = CommandInput
type RetryPostInput = Extract<CommandInput, { method: "post" }>

// Job detail header extracted from JobDetail.tsx: the header action bar
// (HeaderActions + its overflow menu + retry-feedback dialog), the inline
// feedback panel, and the chat-bubble icon. Entry points rendered by the
// route. Depends only on leaf modules and shared UI imports.

export function ChatBubbleIcon() {
  return (
    <svg aria-hidden="true" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="2" viewBox="0 0 24 24">
      <path d="M21 11.5a8.4 8.4 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.4 8.4 0 0 1-3.8-.9L3 21l1.9-5.7a8.4 8.4 0 0 1-.9-3.8 8.5 8.5 0 0 1 17 0Z" />
    </svg>
  )
}

export function HeaderActions({ payload, command, feedbackPanelOpen, onToggleFeedbackPanel, onApprove }: { payload: JobDetailPayload; command: ReturnType<typeof useJobCommand>; feedbackPanelOpen: boolean; onToggleFeedbackPanel: () => void; onApprove?: () => void }) {
  const { t } = useT("jobs")
  const [retryFeedbackOpen, setRetryFeedbackOpen] = useState(false)
  const [retryFeedbackInput, setRetryFeedbackInput] = useState<RetryPostInput | null>(null)
  const actions = headerActions(payload, t)
  const visibleKeys = primaryHeaderActionKeys(payload, actions)
  const visibleActions = visibleKeys.map((key) => actions.find((action) => action.key === key)).filter((action): action is HeaderAction => Boolean(action))
  const overflowActions = actions.filter((action) => !visibleKeys.includes(action.key))
  const canGiveFeedback = ["implemented", "failed", "no_change_needed"].includes(payload.job.state)

  function handleActionClick(action: HeaderAction) {
    if (action.key === "approve" && onApprove) {
      onApprove()
    } else {
      command.mutate(action.input)
    }
  }

  return (
    <>
      <div className="flex flex-wrap items-center justify-end gap-2" data-tour="job-approve">
        {canGiveFeedback ? (
          <button
            aria-expanded={feedbackPanelOpen}
            className={buttonClass("secondary")}
            data-tour="job-feedback"
            onClick={onToggleFeedbackPanel}
            type="button"
          >
            {t("give_feedback")}
          </button>
        ) : null}
        {visibleActions.map((action) => (
          action.key === "approve" && onApprove
            ? (
              <button
                className={buttonClass(action.tone)}
                data-tour="job-approve"
                disabled={command.isPending}
                key={action.key}
                onClick={onApprove}
                type="button"
              >
                {action.label}
              </button>
            )
            : <CommandButton command={command} input={action.input} key={action.key} tone={action.tone}>{action.label}</CommandButton>
        ))}
        {overflowActions.length > 0 ? <HeaderActionsMenu actions={overflowActions} command={command} onActionClick={handleActionClick} onRetryFeedback={(input) => { setRetryFeedbackInput(input); setRetryFeedbackOpen(true) }} /> : null}
      </div>
      {retryFeedbackOpen ? (
        <RetryFeedbackDialog
          command={command}
          input={retryFeedbackInput || { method: "post", path: payload.actions.retry_implementation_action?.path || payload.paths.app_run_again_path }}
          onClose={() => { setRetryFeedbackOpen(false); setRetryFeedbackInput(null) }}
        />
      ) : null}
    </>
  )
}

export function JobFeedbackPanel({ error, isPending, onCancel, onSubmit }: { error: Error | null; isPending: boolean; onCancel: () => void; onSubmit: (body: string) => void }) {
  const { t } = useT("jobs")
  const [body, setBody] = useState("")
  const trimmedBody = body.trim()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!trimmedBody) return

    onSubmit(trimmedBody)
  }

  return (
    <section aria-labelledby="job-feedback-title" className="rounded border border-blue-200 bg-blue-50/60 p-4 dark:border-blue-900/60 dark:bg-blue-950/20">
      <form className="space-y-3" onSubmit={submit}>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100" id="job-feedback-title">{t("feedback_panel_title")}</h2>
        <textarea
          className="w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-blue-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
          disabled={isPending}
          onChange={(event) => setBody(event.target.value)}
          placeholder={t("feedback_placeholder")}
          rows={4}
          value={body}
        />
        {error ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(error, t("feedback_error"))}</p> : null}
        <div className="flex flex-wrap justify-end gap-2">
          <button className={buttonClass("secondary")} disabled={isPending} onClick={onCancel} type="button">{t("cancel")}</button>
          <button className={buttonClass("primary")} disabled={isPending || !trimmedBody} type="submit">
            {isPending ? t("submitting") : t("submit_feedback")}
          </button>
        </div>
      </form>
    </section>
  )
}

function headerActions(payload: JobDetailPayload, t: ReturnType<typeof useT>["t"]): HeaderAction[] {
  const actions = payload.actions
  const paths = payload.paths
  const available: HeaderAction[] = []

  if (actions.can_start) available.push({ key: "start", label: t("start_run"), input: { method: "post", path: paths.app_start_path }, tone: "primary" })
  if (actions.can_poll_feedback) available.push({ key: "poll_feedback", label: t("check_feedback"), input: { method: "post", path: paths.app_poll_feedback_path }, tone: "secondary" })
  if (actions.can_rebase) available.push({ key: "rebase", label: t("rebase_now"), input: { method: "post", path: paths.app_rebase_path }, tone: "secondary" })
  if (actions.can_check_mergeability) available.push({ key: "check_mergeability", label: t("check_mergeability"), input: { method: "post", path: paths.app_check_mergeability_path }, tone: "secondary" })
  if (actions.can_retry_pr_ingestion) available.push({ key: "retry_pr_ingestion", label: t("retry_pr_ingestion"), input: { method: "post", path: paths.app_retry_pr_ingestion_path, confirm: t("confirm_retry_pr_ingestion") }, tone: "primary" })
  if (actions.retry_failed_step_action) available.push({ key: "retry_failed_step", label: actions.retry_failed_step_action.label, input: { method: "post", path: actions.retry_failed_step_action.path }, tone: "primary" })
  if (actions.retry_implementation_action) available.push({ key: "retry_implementation", label: actions.retry_implementation_action.label, input: { method: "post", path: actions.retry_implementation_action.path }, tone: "primary" })
  if (actions.retry_implementation_action) available.push({ key: "retry_feedback", label: t("retry_with_feedback"), input: { method: "post", path: actions.retry_implementation_action.path }, tone: "secondary" })
  if (actions.retry_implementation_action) {
    actions.retry_agent_options.forEach((provider) => {
      const providerName = agentProviderLabel(provider)
      available.push({
        key: `retry_implementation_${provider}`,
        label: t("retry_with_agent", { provider: providerName }),
        input: { method: "post", path: actions.retry_implementation_action!.path, body: { agent_provider: provider } },
        tone: "secondary"
      })
      available.push({
        key: `retry_feedback_${provider}`,
        label: t("retry_with_agent_feedback", { provider: providerName }),
        input: { method: "post", path: actions.retry_implementation_action!.path, body: { agent_provider: provider } },
        tone: "secondary"
      })
    })
  }
  if (actions.can_restart) available.push({ key: "restart", label: t("start_over"), input: { method: "post", path: paths.app_restart_path, confirm: t("confirm_start_over") }, tone: "secondary" })
  if (actions.can_approve) available.push({ key: "approve", label: payload.job.landing_failure_reason ? t("reapprove") : t("approve"), input: { method: "post", path: paths.app_approve_path }, tone: "success" })
  if (actions.can_unapprove) available.push({ key: "unapprove", label: t("unapprove"), input: { method: "post", path: paths.app_unapprove_path, confirm: t("confirm_unapprove") }, tone: "secondary" })
  if (actions.can_open_in_local_mode) available.push({ key: "open_in_local_mode", label: t("open_in_local_mode"), input: { method: "post", path: paths.app_open_in_local_mode_path }, tone: "secondary" })
  if (actions.can_cancel_local_mode) available.push({ key: "cancel_local_mode", label: t("cancel_local_mode"), input: { method: "post", path: paths.app_cancel_local_mode_path, confirm: t("confirm_cancel_local_mode") }, tone: "danger" })
  if (actions.can_cancel) available.push({ key: "cancel", label: t("cancel"), input: { method: "post", path: paths.app_cancel_path, confirm: t("confirm_cancel") }, tone: "danger" })
  if (actions.can_reopen) available.push({ key: "reopen", label: t("reopen"), input: { method: "post", path: paths.app_reopen_path }, tone: "success" })
  if (actions.can_mark_valid) available.push({ key: "mark_valid", label: t("mark_valid"), input: { method: "post", path: paths.app_mark_valid_path }, tone: "secondary" })
  if (actions.can_open_in_coding_mode) available.push({ key: "open_in_coding_mode", label: t("open_in_coding_mode"), input: { method: "post", path: paths.app_open_in_coding_mode_path }, tone: "secondary" })
  available.push({ key: "pin", label: payload.pinned ? t("unpin") : t("pin"), input: payload.pinned ? { method: "delete", path: paths.app_pin_path } : { method: "post", path: paths.app_pin_path }, tone: "secondary" })

  return available
}

function primaryHeaderActionKeys(payload: JobDetailPayload, actions: HeaderAction[]) {
  const availableKeys = new Set(actions.map((action) => action.key))
  const jobState = payload.job.summary_state.toLowerCase()
  const keys: string[] = []

  function add(key: string) {
    if (availableKeys.has(key) && keys.length < 2) keys.push(key)
  }

  if (payload.job.any_active_run || jobState === "running") {
    add("cancel")
  } else if (jobState === "coding") {
    add("cancel_local_mode")
  } else if (availableKeys.has("approve")) {
    add("approve")
    add("retry_failed_step")
  } else if (jobState === "failed" && payload.job.kind === "external_pr") {
    add("retry_pr_ingestion")
    add("restart")
  } else if (jobState === "failed") {
    add("retry_failed_step")
    add("retry_implementation")
    add("restart")
  } else if (jobState === "no_change_needed") {
    add("cancel")
  } else if (availableKeys.has("reopen")) {
    add("reopen")
  } else if (availableKeys.has("retry_failed_step")) {
    add("retry_failed_step")
  } else if (availableKeys.has("retry_implementation")) {
    add("retry_implementation")
  } else {
    add("start")
    add("mark_valid")
  }

  return keys
}

function HeaderActionsMenu({ actions, command, onActionClick, onRetryFeedback }: { actions: HeaderAction[]; command: ReturnType<typeof useJobCommand>; onActionClick: (action: HeaderAction) => void; onRetryFeedback: (input: RetryPostInput) => void }) {
  const [open, setOpen] = useState(false)
  const [alignRight, setAlignRight] = useState(true)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const buttonRef = useRef<HTMLButtonElement>(null)

  function handleToggle() {
    if (!open && buttonRef.current) {
      const rect = buttonRef.current.getBoundingClientRect()
      let containerLeft = 0
      let el: HTMLElement | null = buttonRef.current.parentElement
      while (el && el !== document.documentElement) {
        const ox = window.getComputedStyle(el).overflowX
        if (ox === "auto" || ox === "scroll" || ox === "hidden") {
          containerLeft = el.getBoundingClientRect().left
          break
        }
        el = el.parentElement
      }
      // w-56 = 224px; open left only when the menu won't be clipped by its scroll container
      setAlignRight(rect.right - 224 >= containerLeft)
    }
    setOpen((current) => !current)
  }

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        className={buttonClass("secondary")}
        disabled={command.isPending}
        onClick={handleToggle}
        ref={buttonRef}
        type="button"
      >
        ⋯
      </button>
      {open ? (
        <div className={`absolute ${alignRight ? "right-0" : "left-0"} z-20 mt-2 w-56 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900`} role="menu">
          {actions.map((action) => (
            <button
              className={menuButtonClass(action.tone)}
              disabled={command.isPending}
              key={action.key}
              onClick={() => {
                setOpen(false)
                if (action.key.startsWith("retry_feedback")) {
                  onRetryFeedback(action.input as RetryPostInput)
                  return
                }
                onActionClick(action)
              }}
              role="menuitem"
              type="button"
            >
              {action.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}

function RetryFeedbackDialog({ command, input, onClose }: { command: ReturnType<typeof useJobCommand>; input: RetryPostInput; onClose: () => void }) {
  const { t } = useT("jobs")
  const [feedback, setFeedback] = useState("")
  const trimmedFeedback = feedback.trim()

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!trimmedFeedback) return

    command.mutate(
      { ...input, method: "post", body: { ...(input.body as Record<string, unknown> | undefined), retry_context: trimmedFeedback } },
      { onSuccess: onClose }
    )
  }

  return (
    <div className="fixed inset-0 z-30 flex items-center justify-center bg-gray-900/40 p-4" role="presentation">
      <section aria-labelledby="retry-feedback-title" className="w-full max-w-lg rounded border border-gray-200 bg-white p-4 shadow-xl dark:border-gray-700 dark:bg-gray-900" role="dialog" aria-modal="true">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="retry-feedback-title">{t("retry_feedback_title")}</h2>
            <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t("retry_feedback_description")}</p>
          </div>
          <button
            aria-label={t("close_retry_feedback")}
            className="inline-flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200"
            disabled={command.isPending}
            onClick={onClose}
            type="button"
          >
            <CloseIcon className="h-4 w-4" />
          </button>
        </div>
        <form className="mt-4 space-y-3" onSubmit={submit}>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300" htmlFor="retry-feedback-text">
            {t("retry_feedback_label")}
          </label>
          <textarea
            autoFocus
            className="min-h-36 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-blue-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
            id="retry-feedback-text"
            onChange={(event) => setFeedback(event.target.value)}
            required
            value={feedback}
          />
          <div className="flex flex-wrap justify-end gap-2">
            <button className={buttonClass("secondary")} disabled={command.isPending} onClick={onClose} type="button">{t("cancel")}</button>
            <button className={buttonClass("primary")} disabled={command.isPending || !trimmedFeedback} type="submit">
              {command.isPending ? t("retrying") : t("retry")}
            </button>
          </div>
        </form>
      </section>
    </div>
  )
}

function agentProviderLabel(provider: string) {
  if (provider === "claude") return "Claude Code"
  if (provider === "codex") return "Codex"
  return provider
}
