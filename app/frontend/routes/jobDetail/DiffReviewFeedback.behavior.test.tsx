import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { DiffReviewComment, DiffReviewCommentsPayload } from "../../api/jobs"
import { useDiffReviewFeedback } from "./DiffReviewFeedback"

const apiMocks = vi.hoisted(() => ({
  fetchComments: vi.fn(),
  resolveComment: vi.fn(),
  updateComment: vi.fn()
}))

vi.mock("../../api/jobs", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../../api/jobs")>()),
  fetchDiffReviewComments: apiMocks.fetchComments,
  resolveDiffReviewComment: apiMocks.resolveComment,
  updateDiffReviewComment: apiMocks.updateComment
}))

const file = {
  path: "app/models/job.rb",
  patch: "@@ -1 +1 @@\n-old\n+new",
  status: "modified"
}

const comment: DiffReviewComment = {
  id: 7,
  job_id: 1,
  diff_review_version_id: 2,
  diff_review_version: null,
  parent_id: null,
  user_id: 1,
  user: { id: 1, display_name: "Ada", email_address: "ada@example.com", avatar_url: null },
  workflow_id: null,
  workflow: null,
  run_id: null,
  surface: "job_review",
  base_ref: "main",
  head_ref: "feature",
  anchor_kind: "line",
  path: file.path,
  side: "right",
  old_line: null,
  new_line: 1,
  anchor_key: "right::1",
  diff_hunk: file.patch,
  context: {},
  body: "Original draft",
  state: "draft",
  created_at: null,
  updated_at: null,
  submitted_at: null,
  resolved_at: null,
  superseded_at: null
}

const payload: DiffReviewCommentsPayload = {
  job_id: 1,
  diff_review_version_id: 2,
  latest_version_id: 2,
  comments: [comment],
  by_path: { [file.path]: { [comment.anchor_key]: [comment] } }
}

function FeedbackHarness() {
  const feedback = useDiffReviewFeedback({
    diffReviewVersionId: 2,
    enabled: true,
    jobId: 1,
    surface: "job_review"
  })

  return (
    <>
      {feedback.panel}
      <button onClick={() => feedback.onStartEditThread({ id: comment.id, body: comment.body, state: comment.state })} type="button">
        Start inline edit
      </button>
      {feedback.editingThreadId === comment.id ? (
        <div>
          <textarea aria-label="Inline edit" onChange={(event) => feedback.onChangeEditingThreadBody(event.target.value)} value={feedback.editingThreadBody} />
          <button onClick={feedback.onSaveEditThread} type="button">
            Save inline edit
          </button>
          {feedback.editingThreadError ? <p>{feedback.editingThreadError}</p> : null}
        </div>
      ) : null}
    </>
  )
}

function renderFeedback() {
  const client = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <FeedbackHarness />
    </QueryClientProvider>
  )
}

describe("diff review mutation failures", () => {
  beforeEach(() => {
    apiMocks.fetchComments.mockResolvedValue(payload)
  })

  it("shows a failed inline edit and preserves its draft", async () => {
    apiMocks.updateComment.mockRejectedValue(new Error("Edit failed"))
    renderFeedback()

    await screen.findByText("Original draft")
    fireEvent.click(screen.getByRole("button", { name: "Start inline edit" }))
    const editor = screen.getByLabelText("Inline edit")
    fireEvent.change(editor, { target: { value: "Revised draft" } })
    fireEvent.click(screen.getByRole("button", { name: "Save inline edit" }))

    expect(await screen.findByText("Unable to update diff comment.")).toBeInTheDocument()
    expect(screen.getByLabelText("Inline edit")).toHaveValue("Revised draft")
  })

  it("shows a failed resolve beside the affected comment", async () => {
    apiMocks.resolveComment.mockRejectedValue(new Error("Resolve failed"))
    renderFeedback()

    fireEvent.click(await screen.findByRole("button", { name: "Resolve" }))

    await waitFor(() => expect(screen.getByText("Unable to resolve diff comment.")).toBeInTheDocument())
    expect(screen.getByText("Original draft").closest("[data-diff-review-comment-id]")).toHaveTextContent("Unable to resolve diff comment.")
  })
})
