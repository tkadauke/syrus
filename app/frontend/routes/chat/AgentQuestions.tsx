import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { answerAgentQuestion, type ChatAgentQuestion, type ChatAgentQuestionAnswer, type ChatAgentSubQuestion } from "../../api/chats"
import { Checkbox } from "../../components/Checkbox"
import { Input } from "../../components/Input"
import { Stepper } from "../../components/Stepper"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { Markdown } from "../../lib/Markdown"
import { type ChatQueryKey } from "./constants"
import { appendSearch, primaryButton, secondaryButton } from "./utils"

export const DECLINE_ANSWER = "I decline to answer."

// Draft state for one sub-question, held client-side until the whole card is
// submitted: a plain string for single-select/free-text, a string array for
// multi-select, or null before the step has been answered.
type AgentAnswerDraft = string | string[] | null

export function AgentQuestions({ questions, queryKey, onNotice }: { questions: ChatAgentQuestion[]; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  return (
    <section aria-label={t("aria_agent_questions")} className="w-full max-w-3xl space-y-3 rounded border border-info/30 bg-info/10 p-3">
      {questions.map((question) => <AgentQuestionCard key={question.id} question={question} queryKey={queryKey} onNotice={onNotice} />)}
    </section>
  )
}

function AgentQuestionCard({ question, queryKey, onNotice }: { question: ChatAgentQuestion; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const subQuestions = question.questions
  const single = subQuestions.length === 1
  const [stepIndex, setStepIndex] = useState(0)
  const [phase, setPhase] = useState<"step" | "summary">("step")
  const [drafts, setDrafts] = useState<AgentAnswerDraft[]>(() => subQuestions.map(() => null))

  const submit = useMutation({
    mutationFn: (answers: ChatAgentQuestionAnswer[]) => answerAgentQuestion(appendSearch(question.app_answer_path, search), answers),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  function commitStep(index: number, value: string | string[]) {
    setDrafts((current) => {
      const next = current.slice()
      next[index] = value
      return next
    })

    if (single) {
      submit.mutate([value])
      return
    }

    if (index === subQuestions.length - 1) {
      setPhase("summary")
    } else {
      setStepIndex(index + 1)
    }
  }

  function goBack() {
    if (phase === "summary") {
      setPhase("step")
      return
    }
    setStepIndex((index) => Math.max(0, index - 1))
  }

  function submitAll() {
    if (submit.isPending) return
    submit.mutate(drafts as ChatAgentQuestionAnswer[])
  }

  const errorBanner = submit.isError ? <div className="text-xs text-red-700 dark:text-red-300">{errorMessage(submit.error, "Answer could not be submitted.")}</div> : null

  if (phase === "summary") {
    return (
      <div className="space-y-3 rounded border border-info/30 bg-white p-3 text-sm dark:bg-gray-950">
        {errorBanner}
        <h3 className="font-medium text-gray-900 dark:text-gray-100">{t("review_your_answers")}</h3>
        <ol className="space-y-2">
          {subQuestions.map((subQuestion, index) => (
            <li className="rounded border border-gray-200 p-2 dark:border-gray-700" key={index}>
              <Markdown className="font-medium text-gray-900 dark:text-gray-100" text={subQuestion.question} />
              <p className="mt-1 text-gray-600 dark:text-gray-400">{formatDraftAnswer(drafts[index], t)}</p>
            </li>
          ))}
        </ol>
        <div className="flex gap-2">
          <button className={secondaryButton()} disabled={submit.isPending} onClick={goBack} type="button">{t("back")}</button>
          <button className={primaryButton()} disabled={submit.isPending} onClick={submitAll} type="button">{t("submit_all_answers")}</button>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-2">
      {errorBanner}
      {!single ? (
        <Stepper
          active={String(stepIndex)}
          steps={subQuestions.map((_, index) => ({
            key: String(index),
            label: t("wizard_step_label", { number: index + 1 }),
            done: drafts[index] != null
          }))}
        />
      ) : null}
      <AgentQuestionStepField
        disabled={submit.isPending}
        draft={drafts[stepIndex]}
        key={stepIndex}
        subQuestion={subQuestions[stepIndex]}
        onCommit={(value) => commitStep(stepIndex, value)}
      />
      {!single && stepIndex > 0 ? (
        <button className={secondaryButton()} disabled={submit.isPending} onClick={goBack} type="button">{t("back")}</button>
      ) : null}
    </div>
  )
}

function AgentQuestionStepField({ subQuestion, draft, disabled, onCommit }: { subQuestion: ChatAgentSubQuestion; draft: AgentAnswerDraft; disabled: boolean; onCommit: (value: string | string[]) => void }) {
  const { t } = useT("chat")
  const options = subQuestion.options?.filter((option) => option.trim().length > 0) || []
  const [text, setText] = useState(() => (typeof draft === "string" ? draft : ""))
  const [selected, setSelected] = useState<string[]>(() => (Array.isArray(draft) ? draft : []))

  function toggleOption(option: string) {
    setSelected((current) => current.includes(option) ? current.filter((value) => value !== option) : [...current, option])
  }

  function submitText(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const value = text.trim()
    if (value.length === 0 || disabled) return

    onCommit(value)
  }

  function submitSelection() {
    if (selected.length === 0 || disabled) return

    onCommit(selected)
  }

  function decline() {
    if (disabled) return

    onCommit(subQuestion.multiple ? [DECLINE_ANSWER] : DECLINE_ANSWER)
  }

  return (
    <div className="space-y-3 rounded border border-info/30 bg-white p-3 text-sm dark:bg-gray-950">
      <Markdown className="font-medium text-gray-900 dark:text-gray-100" text={subQuestion.question} />
      {options.length > 0 && subQuestion.multiple ? (
        <div className="flex flex-col gap-2">
          {options.map((option) => (
            <label className="flex items-center gap-2 rounded border border-gray-200 px-3 py-2 dark:border-gray-700" key={option}>
              <Checkbox
                aria-label={t("aria_multi_select_option", { option })}
                checked={selected.includes(option)}
                disabled={disabled}
                onChange={() => toggleOption(option)}
              />
              {option}
            </label>
          ))}
          <button className={primaryButton()} disabled={disabled || selected.length === 0} onClick={submitSelection} type="button">{t("submit")}</button>
        </div>
      ) : (
        <>
          {options.length > 0 ? (
            <div className="flex flex-col gap-2">
              {options.map((option) => (
                <button className={`${secondaryButton()} flex w-full justify-start text-left`} disabled={disabled} key={option} onClick={() => onCommit(option)} type="button">
                  {option}
                </button>
              ))}
            </div>
          ) : null}
          <form className="flex flex-col gap-2 sm:flex-row" onSubmit={submitText}>
            <Input
              aria-label={t("aria_custom_answer")}
              className="min-h-9 flex-1"
              disabled={disabled}
              onChange={(event) => setText(event.target.value)}
              placeholder={t("ph_custom_response")}
              value={text}
            />
            <button className={primaryButton()} disabled={disabled || text.trim().length === 0} type="submit">{t("submit")}</button>
          </form>
        </>
      )}
      <button className={`${secondaryButton()} flex w-full justify-start text-left`} disabled={disabled} onClick={decline} type="button">
        {t("decline_to_answer")}
      </button>
    </div>
  )
}

function formatDraftAnswer(draft: AgentAnswerDraft, t: (key: string) => string): string {
  if (Array.isArray(draft)) {
    if (draft.length === 1 && draft[0] === DECLINE_ANSWER) return t("declined")
    return draft.join(", ")
  }
  if (draft === DECLINE_ANSWER) return t("declined")
  return draft ?? ""
}
