import { useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useRef, useState } from "react"
import { createPortal } from "react-dom"
import { Link } from "react-router-dom"
import { answerWorkflowAgentQuestion, fetchOpenAgentQuestions, type WorkflowAgentQuestion } from "../api/agentQuestions"
import type { ChatAgentQuestionAnswer } from "../api/chats"
import { useT } from "../hooks/useT"
import { withRoutePrefix } from "../lib/routing"
import { AgentQuestions } from "../routes/chat/AgentQuestions"
import { ACTIVITY_MOBILE_QUERY, useMediaQuery } from "../hooks/useMediaQuery"
import { useActivity } from "./activity/ActivityContext"

export const openQuestionsQueryKey = ["agent-questions", "open"] as const
const CONTROL_CLASS = "relative inline-flex h-9 w-9 items-center justify-center rounded text-text-secondary hover:bg-surface-subtle hover:text-brand-emphasis"
const DRAWER_CLASS = "fixed inset-y-0 right-0 z-50 w-full max-w-md overflow-y-auto border-l border-border bg-surface p-4 shadow-xl"
const BADGE_CLASS = "absolute -right-1 -top-1 min-w-5 rounded-full bg-warning px-1.5 py-0.5 text-center text-2xs font-semibold leading-none text-surface"
const ARRIVAL_BANNER_CLASS =
  "fixed right-4 top-4 z-50 max-w-sm rounded border border-warning-border bg-surface px-4 py-3 text-sm font-medium text-text-primary shadow-xl"
const ARRIVAL_NOTICE_MS = 5_000

export function QuestionInboxDrawer({ prefix = "", onNavigate }: { prefix?: string; onNavigate?: () => void }) {
  const { t } = useT("nav")
  const client = useQueryClient()
  const [open, setOpen] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [announcement, setAnnouncement] = useState("")
  const previousCount = useRef<number | null>(null)
  const clearAnnouncementTimeout = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const activity = useActivity()
  const isMobile = useMediaQuery(ACTIVITY_MOBILE_QUERY)
  const showInActivity = Boolean(activity && isMobile)
  const questions = useOpenAgentQuestions()
  const openQuestions = questions.data?.questions ?? []
  const count = openQuestions.length

  useEffect(() => {
    if (previousCount.current != null && count > previousCount.current) {
      clearTimeout(clearAnnouncementTimeout.current)
      setAnnouncement(t("question_inbox.arrived", { count: count - previousCount.current }))
      clearAnnouncementTimeout.current = setTimeout(() => setAnnouncement(""), ARRIVAL_NOTICE_MS)
    } else if (previousCount.current != null && count < previousCount.current) {
      clearTimeout(clearAnnouncementTimeout.current)
      setAnnouncement("")
    }
    previousCount.current = count
  }, [count, t])

  useEffect(() => () => clearTimeout(clearAnnouncementTimeout.current), [])

  async function answer(question: WorkflowAgentQuestion, answers: ChatAgentQuestionAnswer[]) {
    const result = await answerWorkflowAgentQuestion(question.app_answer_path, answers)
    await client.invalidateQueries({ queryKey: openQuestionsQueryKey })
    return result
  }

  return (
    <div className="relative">
      <button
        aria-expanded={showInActivity ? activity?.open && activity.tab === "questions" : open}
        aria-haspopup="dialog"
        aria-label={t("question_inbox.open", { count })}
        className={CONTROL_CLASS}
        onClick={(event) => {
          if (activity && showInActivity) activity.openActivity("questions", { invoker: event.currentTarget, onNavigate })
          else setOpen((value) => !value)
        }}
        type="button"
      >
        <QuestionIcon />
        {count ? <span className={BADGE_CLASS}>{count > 9 ? "9+" : count}</span> : null}
      </button>
      <span aria-live="assertive" className="sr-only">
        {announcement}
      </span>
      {announcement && !showInActivity ? (
        <div className={ARRIVAL_BANNER_CLASS} role="status">
          {announcement}
        </div>
      ) : null}
      {open && !showInActivity
        ? createPortal(
            <aside aria-label={t("question_inbox.title")} className={DRAWER_CLASS}>
              <header className="mb-4 flex items-center justify-between gap-3">
                <h2 className="text-lg font-semibold">{t("question_inbox.title")}</h2>
                <button className="text-sm text-text-secondary" onClick={() => setOpen(false)} type="button">
                  {t("question_inbox.close")}
                </button>
              </header>
              {notice ? <p className="mb-3 text-sm text-success-text">{notice}</p> : null}
              <div className="space-y-4">
                {openQuestions.map((question) => (
                  <article className="space-y-2" key={question.id}>
                    <Link
                      className="block text-sm font-semibold text-brand hover:underline"
                      onClick={onNavigate}
                      to={withRoutePrefix(question.job_path, prefix)}
                    >
                      {question.job_slug}: {question.job_title}
                    </Link>
                    <AgentQuestions
                      questions={[question]}
                      onAnswered={(item, answers) => answer(item as WorkflowAgentQuestion, answers)}
                      onNotice={setNotice}
                    />
                  </article>
                ))}
              </div>
              {questions.isSuccess && count === 0 ? <p className="text-sm text-text-muted">{t("question_inbox.empty")}</p> : null}
            </aside>,
            document.body
          )
        : null}
    </div>
  )
}

export function useOpenAgentQuestions() {
  return useQuery({ queryKey: openQuestionsQueryKey, queryFn: () => fetchOpenAgentQuestions(), refetchInterval: 15_000 })
}

export function QuestionsActivityPanel({ navigateTo, prefix }: { navigateTo: (to: string) => void; prefix: string }) {
  const { t } = useT("nav")
  const client = useQueryClient()
  const questions = useOpenAgentQuestions()
  const openQuestions = questions.data?.questions ?? []
  const [notice, setNotice] = useState<string | null>(null)
  async function answer(question: WorkflowAgentQuestion, answers: ChatAgentQuestionAnswer[]) {
    const result = await answerWorkflowAgentQuestion(question.app_answer_path, answers)
    await client.invalidateQueries({ queryKey: openQuestionsQueryKey })
    return result
  }
  return (
    <div className="space-y-4 p-4">
      {notice ? <p className="text-sm text-success-text">{notice}</p> : null}
      {openQuestions.map((question) => (
        <article className="space-y-2" key={question.id}>
          <Link
            className="block text-sm font-semibold text-brand hover:underline"
            onClick={(event) => {
              event.preventDefault()
              navigateTo(withRoutePrefix(question.job_path, prefix))
            }}
            to={withRoutePrefix(question.job_path, prefix)}
          >
            {question.job_slug}: {question.job_title}
          </Link>
          <AgentQuestions questions={[question]} onAnswered={(item, answers) => answer(item as WorkflowAgentQuestion, answers)} onNotice={setNotice} />
        </article>
      ))}
      {questions.isSuccess && openQuestions.length === 0 ? <p className="text-sm text-text-muted">{t("question_inbox.empty")}</p> : null}
    </div>
  )
}

function QuestionIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.8" />
      <path d="M9.8 9a2.3 2.3 0 1 1 3.5 2c-.9.5-1.3 1-1.3 2" stroke="currentColor" strokeLinecap="round" strokeWidth="1.8" />
      <path d="M12 16.5h.01" stroke="currentColor" strokeLinecap="round" strokeWidth="2" />
    </svg>
  )
}
