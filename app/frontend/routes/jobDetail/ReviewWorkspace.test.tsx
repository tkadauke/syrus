import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { ReviewWorkspace } from "./ReviewWorkspace"
import {
  createDiffReviewComment,
  fetchDiffReviewComments,
  fetchJobSourceDiff,
  submitDiffReviewComments,
  updateDiffReviewComment,
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
  vi.mocked(updateDiffReviewComment).mockReset()
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

  it("renders every changed file's diff without an internal max-height and navigates via the changed-files popup", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Implementation review")
    expect(screen.getByText("new")).toBeInTheDocument()
    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByTestId("agent-diff-viewer").querySelector(".max-h-\\[32rem\\]")).not.toBeInTheDocument()

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])
    expect(screen.getByText("Changed files")).toBeInTheDocument()

    const target = document.querySelector('[data-diff-file="app/models/run.rb"]') as HTMLElement
    const scrollSpy = vi.fn()
    target.scrollIntoView = scrollSpy

    fireEvent.click(screen.getByTitle("app/models/run.rb (+1 -0)"))

    expect(scrollSpy).toHaveBeenCalled()
    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
  })

  it("starts review artifacts collapsed and expands them on demand", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Review artifacts")
    expect(screen.queryByText("Review the diff")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Show" }))
    expect(screen.getByText("Review the diff")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Hide" }))
    expect(screen.queryByText("Review the diff")).not.toBeInTheDocument()
  })

  it("renders typed artifacts inline instead of a bare renderer_type label", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace({
      ...jobPayload(),
      typed_artifacts: [
        {
          type: "rails_migration_diff",
          title: "Migration: add_name_to_users",
          payload: { headers: ["Column", "Type"], rows: [["name", "string"]] },
          created_at: "2026-01-01T00:00:00Z",
          renderer_type: "data_table"
        }
      ]
    })

    await screen.findByText("Review artifacts")
    fireEvent.click(screen.getByRole("button", { name: "Show" }))

    expect(screen.getByText("Migration: add_name_to_users")).toBeInTheDocument()
    expect(screen.getByText("Column")).toBeInTheDocument()
    expect(screen.getByText("name")).toBeInTheDocument()
    expect(screen.queryByText("data_table")).not.toBeInTheDocument()
  })

  it("creates a whole-review comment not anchored to any code line", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(createDiffReviewComment).mockResolvedValue(commentsPayload([
      comment({ anchor_kind: "review", path: null, side: null, new_line: null, anchor_key: "review", body: "Looks great overall." })
    ]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Comment on this review" }))
    fireEvent.change(screen.getByLabelText("Comment"), { target: { value: "Looks great overall." } })
    fireEvent.click(screen.getByRole("button", { name: "Create comment" }))

    await waitFor(() => {
      expect(createDiffReviewComment).toHaveBeenCalledWith(42, expect.objectContaining({
        anchor_kind: "review",
        body: "Looks great overall.",
        surface: "job_review_workspace"
      }))
    })
  })

  it("makes the comments sidebar a sticky, viewport-height column", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const sidebarSection = await screen.findByText("Diff comments")
    const stickyWrapper = sidebarSection.closest("section")?.parentElement
    expect(stickyWrapper).toHaveClass("lg:sticky", "lg:top-0", "lg:h-screen", "lg:overflow-y-auto")
  })

  it("shows both code-anchored and whole-review comments together in the sidebar", async () => {
    const lineComment = comment({ id: 1, new_line: 1, anchor_key: "right::1", body: "Please add a regression spec." })
    const globalComment = comment({
      id: 2,
      anchor_kind: "review",
      path: null,
      side: null,
      new_line: null,
      anchor_key: "review",
      body: "Looks great overall."
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([lineComment, globalComment]))

    renderWorkspace()

    await screen.findByText("Looks great overall.")
    const sidebar = within(screen.getByText("Diff comments").closest("section") as HTMLElement)
    expect(sidebar.getAllByText("Please add a regression spec.").length).toBeGreaterThan(0)
    expect(sidebar.getByText("Looks great overall.")).toBeInTheDocument()
    expect(sidebar.getByText("Whole-review comment")).toBeInTheDocument()
    expect(sidebar.getByRole("button", { name: "Edit" })).toBeInTheDocument()
  })

  it("shows code-anchored comments in the sidebar without a sidebar edit affordance, and edits them inline in the diff", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment({ new_line: 1, anchor_key: "right::1" })]))
    vi.mocked(updateDiffReviewComment).mockResolvedValue(commentsPayload([comment({ body: "Updated body." })]))

    renderWorkspace()

    await screen.findAllByText("Please add a regression spec.")
    const sidebar = within(screen.getByText("Diff comments").closest("section") as HTMLElement)
    expect(sidebar.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument()
    expect(sidebar.getByRole("button", { name: "View in diff" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Edit" }))
    fireEvent.change(screen.getByLabelText("Edit comment 1"), { target: { value: "Updated body." } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(updateDiffReviewComment).toHaveBeenCalledWith(42, 1, { body: "Updated body." })
    })
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

  it("does not resubmit comments whose feedback workflow already succeeded", async () => {
    const handled = comment({
      id: 1,
      state: "submitted",
      workflow_id: 8,
      workflow: { id: 8, trigger_kind: "chat_feedback", state: "succeeded" }
    })
    const retryable = comment({
      id: 2,
      state: "submitted",
      workflow_id: 9,
      workflow: { id: 9, trigger_kind: "chat_feedback", state: "failed" }
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([handled, retryable]))
    vi.mocked(submitDiffReviewComments).mockResolvedValue({
      message: "Diff comments submitted as chat feedback.",
      workflow: { id: 10, trigger_kind: "chat_feedback", state: "queued" },
      comments: [retryable]
    })

    renderWorkspace()

    await screen.findByText("1 handled")
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    await waitFor(() => {
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [2])
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
    anchor_kind: "line",
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
