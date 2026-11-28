import { getJson, postJson } from "./client"
import type { ChatAgentQuestion, ChatAgentQuestionAnswer } from "./chats"

export type WorkflowAgentQuestion = ChatAgentQuestion & {
  job_id: number
  job_slug: string
  job_title: string
  repository_slug: string
  times_out_at: string | null
  job_path: string
}

export function fetchOpenAgentQuestions(jobId?: number) {
  const search = jobId == null ? "" : `?job_id=${jobId}`
  return getJson<{ questions: WorkflowAgentQuestion[] }>(`/api/v1/app/agent_questions${search}`)
}

export function answerWorkflowAgentQuestion(path: string, answers: ChatAgentQuestionAnswer[]) {
  return postJson<{ message: string }>(path, { answers })
}
