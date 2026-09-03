import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ReviewWorkspace } from "./ReviewWorkspace"
import {
  createDiffReviewComment,
  fetchDiffReviewComments,
  fetchJobSourceDiff,
  submitDiffReviewComments,
  type DiffReviewComment,
  type DiffReviewCommentsPayload,
  type JobDetailPayload,
  type JobSourceDiffPayload
} from "../../api/jobs"

vi.mock("../../api/jobs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/jobs")>()
  return {
    ...actual,
    createDiffReviewComment: vi.fn(),
    fetchDiffReviewComments: vi.fn(),
    fetchJobSourceDiff: vi.fn(),
    resolveDiffReviewComment: vi.fn(),
    submitDiffReviewComments: vi.fn(),
    updateDiffReviewComment: vi.fn()
  }
})

beforeEach(() => {
  vi.mocked(createDiffReviewComment).mockReset()
  vi.mocked(fetchDiffReviewComments).mockReset()
  vi.mocked(fetchJobSourceDiff).mockReset()
  vi.mocked(submitDiffReviewComments).mockReset()
  Element.prototype.scrollIntoView = vi.fn()
})

function renderWorkspace(payload = jobPayload()) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ReviewWorkspace payload={payload} />
    </QueryClientProvider>
  )
}

describe("ReviewWorkspace", () => {
  it("creates anchored comments from continuous diff lines", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(createDiffReviewComment).mockResolvedValue(commentsPayload([comment()]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Comment on app/models/user.rb:new:1" }))
    fireEvent.change(screen.getByLabelText("Comment"), { target: { value: "Please add a regression spec." } })
    fireEvent.click(screen.getByRole("button", { name: "Create comment" }))

    await waitFor(() => {
      expect(createDiffReviewComment).toHaveBeenCalledWith(42, expect.objectContaining({
        body: "Please add a regression spec.",
        base_ref: "base-sha",
        head_ref: "head-sha",
        path: "app/models/user.rb",
        side: "right",
        new_line: 1,
        surface: "job_review_workspace"
      }))
    })
  })

  it("navigates from the changed-file list to the continuous diff", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Implementation review")
    const row = screen.getByTitle("app/models/run.rb (+1 -0)")
    fireEvent.click(row)

    expect(row).toHaveClass("text-brand")
    expect(screen.getByText("added")).toBeInTheDocument()
  })

  it("submits actionable comments as chat feedback", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment()]))
    vi.mocked(submitDiffReviewComments).mockResolvedValue({
      message: "Diff comments submitted as chat feedback.",
      workflow: { id: 7, trigger_kind: "chat_feedback", state: "queued" },
      comments: [comment({ state: "submitted", workflow: { id: 7, trigger_kind: "chat_feedback", state: "queued" } })]
    })

    renderWorkspace()

    await screen.findByText("Please add a regression spec.")
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    await waitFor(() => {
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [1])
    })
  })
})

function sourceDiffPayload(): JobSourceDiffPayload {
  return {
    job_id: 42,
    base_ref: "base-sha",
    head_ref: "head-sha",
    merge_base_sha: "base-sha",
    default_ref: "main",
    branch_commits: [],
    truncated: false,
    diff_error: null,
    files: [
      {
        additions: 1,
        deletions: 1,
        path: "app/models/user.rb",
        status: "modified",
        patch: [
          "diff --git a/app/models/user.rb b/app/models/user.rb",
          "--- a/app/models/user.rb",
          "+++ b/app/models/user.rb",
          "@@ -1,2 +1,2 @@",
          "-old",
          "+new"
        ].join("\n")
      },
      {
        additions: 1,
        deletions: 0,
        path: "app/models/run.rb",
        status: "modified",
        patch: [
          "diff --git a/app/models/run.rb b/app/models/run.rb",
          "--- a/app/models/run.rb",
          "+++ b/app/models/run.rb",
          "@@ -4,1 +4,2 @@",
          " context",
          "+added"
        ].join("\n")
      }
    ]
  }
}

function commentsPayload(comments: DiffReviewComment[]): DiffReviewCommentsPayload {
  return { job_id: 42, comments, by_path: {} }
}

function comment(overrides: Partial<DiffReviewComment> = {}): DiffReviewComment {
  return {
    id: 1,
    job_id: 42,
    user_id: 5,
    user: { id: 5, display_name: "Ada", email_address: "ada@example.com", avatar_url: null },
    workflow_id: null,
    workflow: null,
    run_id: null,
    surface: "job_review_workspace",
    base_ref: "base-sha",
    head_ref: "head-sha",
    path: "app/models/user.rb",
    side: "right",
    old_line: null,
    new_line: 2,
    anchor_key: "right::2",
    diff_hunk: "@@ -1,2 +1,2 @@\n-old\n+new",
    context: {},
    body: "Please add a regression spec.",
    state: "draft",
    created_at: null,
    updated_at: null,
    submitted_at: null,
    resolved_at: null,
    superseded_at: null,
    ...overrides
  }
}

function jobPayload(): JobDetailPayload {
  return {
    job: {
      id: 42,
      state: "implemented",
      summary_state: "implemented"
    },
    repository: { id: 1, slug: "acme/widgets", owner: "acme", name: "widgets", default_branch: "main", review_policy: "self", feedback_policy: "confirm", main_health: "healthy", landing_paused: false, main_branch_repair_blocks_work: false, repository_path: "/repositories/1", edit_repository_path: "/repositories/1/edit" },
    epic: null,
    origin_chat: null,
    pinned: false,
    tags: [],
    tag_options: [],
    dependencies: [],
    dependents: [],
    unsatisfied_dependencies: [],
    dependency_target_options: [],
    epic_dependency_target_options: [],
    attachments: [],
    pr_links: [],
    typed_artifacts: [],
    coverage: null,
    summary: { run_id: 9, text: "Implemented the requested change.", finished_at: null },
    test_plan: { workflow_id: 2, steps: ["Review the diff"], notes: null },
    feedback_history: [],
    pending_feedback: [],
    landing_queue_entry: null,
    preview: null,
    deploy: null,
    workflows: [],
    workflows_pagination: { page: 1, per_page: 20, total_workflows: 0, total_pages: 0, first_item: 0, last_item: 0, previous_path: null, next_path: null },
    actions: {} as JobDetailPayload["actions"],
    paths: {} as JobDetailPayload["paths"]
  } as unknown as JobDetailPayload
}
