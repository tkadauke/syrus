import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { stubVirtualizerMeasurements } from "../../test/virtualizerMeasurements"
import * as performanceMarkers from "../../lib/performanceMarkers"
import { ReviewWorkspace } from "./ReviewWorkspace"

stubVirtualizerMeasurements()
import {
  createDiffReviewComment,
  deleteDiffReviewComment,
  fetchDiffReviewVersion,
  fetchDiffReviewComments,
  fetchJobSourceDiff,
  replyToDiffReviewComment,
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
    deleteDiffReviewComment: vi.fn(),
    fetchDiffReviewComments: vi.fn(),
    fetchDiffReviewVersion: vi.fn(),
    fetchJobSourceDiff: vi.fn(),
    replyToDiffReviewComment: vi.fn(),
    resolveDiffReviewComment: vi.fn(),
    submitDiffReviewComments: vi.fn(),
    updateDiffReviewComment: vi.fn()
  }
})

beforeEach(() => {
  vi.mocked(createDiffReviewComment).mockReset()
  vi.mocked(deleteDiffReviewComment).mockReset()
  vi.mocked(fetchDiffReviewComments).mockReset()
  vi.mocked(fetchDiffReviewVersion).mockReset()
  vi.mocked(fetchJobSourceDiff).mockReset()
  vi.mocked(replyToDiffReviewComment).mockReset()
  vi.mocked(submitDiffReviewComments).mockReset()
  vi.mocked(updateDiffReviewComment).mockReset()
  HTMLElement.prototype.scrollIntoView = vi.fn()
})

function renderWorkspace(payload = jobPayload()) {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ReviewWorkspace payload={payload} />
    </QueryClientProvider>
  )
}

describe("ReviewWorkspace", () => {
  it("creates anchored comments from continuous diff lines, composed inline in the diff rather than the sidebar", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(createDiffReviewComment).mockResolvedValue(commentsPayload([comment()]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Comment on app/models/user.rb:new:1" }))

    const composer = screen.getByTestId("diff-review-composer")
    const sidebar = screen.getByText("Diff comments").closest("section") as HTMLElement
    expect(sidebar.contains(composer)).toBe(false)
    expect(within(composer).getByLabelText("Comment")).toBeInTheDocument()

    fireEvent.change(within(composer).getByLabelText("Comment"), { target: { value: "Please add a regression spec." } })
    fireEvent.click(within(composer).getByRole("button", { name: "Create comment" }))

    await waitFor(() => {
      expect(createDiffReviewComment).toHaveBeenCalledWith(42, expect.objectContaining({
        body: "Please add a regression spec.",
        diff_review_version_id: 100,
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

  it("creates a whole-review comment from the permanent comment form", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(createDiffReviewComment).mockResolvedValue(commentsPayload([
      comment({ anchor_kind: "review", path: null, side: null, new_line: null, anchor_key: "review", body: "Looks great overall." })
    ]))

    renderWorkspace()

    expect(screen.queryByRole("button", { name: "Comment on this review" })).not.toBeInTheDocument()
    const commentButton = await screen.findByRole("button", { name: "Comment" })
    expect(commentButton).toBeDisabled()

    fireEvent.change(screen.getByLabelText("Whole-review comment"), { target: { value: "Looks great overall." } })
    expect(commentButton).not.toBeDisabled()
    fireEvent.click(commentButton)

    await waitFor(() => {
      expect(createDiffReviewComment).toHaveBeenCalledWith(42, expect.objectContaining({
        anchor_kind: "review",
        body: "Looks great overall.",
        diff_review_version_id: 100,
        surface: "job_review_workspace"
      }))
    })
    await waitFor(() => {
      expect(screen.getByLabelText("Whole-review comment")).toHaveValue("")
    })
  })

  it("creates a comment from non-empty text then submits the whole review when Submit feedback is clicked", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment({ id: 1 })]))
    vi.mocked(createDiffReviewComment).mockResolvedValue(commentsPayload([
      comment({ id: 2, anchor_kind: "review", path: null, side: null, new_line: null, anchor_key: "review", body: "One more thing." })
    ]))
    vi.mocked(submitDiffReviewComments).mockResolvedValue({
      message: "Diff comments submitted as chat feedback.",
      workflow: { id: 7, trigger_kind: "chat_feedback", state: "queued" },
      comments: []
    })

    renderWorkspace()

    await screen.findByText("Please add a regression spec.")
    fireEvent.change(screen.getByLabelText("Whole-review comment"), { target: { value: "One more thing." } })
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    await waitFor(() => {
      expect(createDiffReviewComment).toHaveBeenCalledWith(42, expect.objectContaining({
        anchor_kind: "review",
        body: "One more thing.",
        diff_review_version_id: 100,
        surface: "job_review_workspace"
      }))
    })
    await waitFor(() => {
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [1, 2], 100)
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

  it("keeps the sidebar column from stretching the mobile grid track past the viewport", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const sidebarSection = await screen.findByText("Diff comments")
    const stickyWrapper = sidebarSection.closest("section")?.parentElement
    expect(stickyWrapper).toHaveClass("min-w-0")
  })

  it("wraps long review artifact and test plan text instead of letting it overflow", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Show" }))
    const step = screen.getByText("Review the diff")
    expect(step.tagName).toBe("LI")
    expect(step).toHaveClass("break-words")
  })

  it("falls back to horizontal scroll within each review artifact tile when wrapping isn't enough", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Show" }))
    const testPlanTile = screen.getByText("Test plan").closest("div")
    expect(testPlanTile).toHaveClass("overflow-x-auto")
  })

  it("wraps long comment bodies and paths instead of letting them overflow the sidebar", async () => {
    const longPathComment = comment({
      body: "A very long comment body with no natural wrap points: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
      path: "app/services/some/deeply/nested/module/with/a/very/long/unbroken/file_name_that_could_overflow_a_narrow_sidebar.rb"
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([longPathComment]))

    renderWorkspace()

    const body = await screen.findByText(longPathComment.body)
    expect(body).toHaveClass("break-words")
    const pathLabel = screen.getByText(`${longPathComment.path}:2`)
    expect(pathLabel).toHaveClass("break-words")
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
      expect(updateDiffReviewComment).toHaveBeenCalledWith(42, 1, { body: "Updated body.", diff_review_version_id: 100 })
    })
  })

  it("shows a little surrounding diff context above and below a code-anchored comment in the sidebar", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([
      comment({
        new_line: 1,
        anchor_key: "right::1",
        diff_hunk: "@@ -1,2 +1,2 @@\n-old\n+new",
        context: { line_kind: "add", line_text: "new" }
      })
    ]))

    renderWorkspace()

    await screen.findByText("Diff comments")
    await waitFor(() => expect(screen.queryByText("No diff comments.")).not.toBeInTheDocument())
    const sidebar = within(screen.getByText("Diff comments").closest("section") as HTMLElement)
    expect(sidebar.getByText("@@ -1,2 +1,2 @@")).toBeInTheDocument()
    expect(sidebar.getByText("-old")).toBeInTheDocument()
    expect(sidebar.getByText("+new")).toHaveClass("ring-brand")
  })

  it("deletes a draft global comment from the sidebar after confirming", async () => {
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
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([globalComment]))
    vi.mocked(deleteDiffReviewComment).mockResolvedValue({ job_id: 42, deleted_id: 2 })

    renderWorkspace()

    await screen.findByText("Looks great overall.")
    fireEvent.click(screen.getByRole("button", { name: "Delete" }))

    const dialog = await screen.findByRole("dialog")
    fireEvent.click(within(dialog).getByRole("button", { name: "Delete" }))

    await waitFor(() => {
      expect(deleteDiffReviewComment).toHaveBeenCalledWith(42, 2, 100)
    })
  })

  it("does not delete a comment when the confirmation dialog is cancelled", async () => {
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
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([globalComment]))

    renderWorkspace()

    await screen.findByText("Looks great overall.")
    fireEvent.click(screen.getByRole("button", { name: "Delete" }))

    const dialog = await screen.findByRole("dialog")
    fireEvent.click(within(dialog).getByRole("button", { name: "Cancel" }))

    expect(deleteDiffReviewComment).not.toHaveBeenCalled()
  })

  it("deletes a draft code-anchored comment inline from the diff after confirming", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment({ new_line: 1, anchor_key: "right::1" })]))
    vi.mocked(deleteDiffReviewComment).mockResolvedValue({ job_id: 42, deleted_id: 1 })

    renderWorkspace()

    await screen.findAllByText("Please add a regression spec.")
    fireEvent.click(screen.getByRole("button", { name: "Delete" }))

    const dialog = await screen.findByRole("dialog")
    fireEvent.click(within(dialog).getByRole("button", { name: "Delete" }))

    await waitFor(() => {
      expect(deleteDiffReviewComment).toHaveBeenCalledWith(42, 1, 100)
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
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [1], 100)
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
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [2], 100)
    })
  })

  it("lets any eligible user reply to an existing comment", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment()]))
    vi.mocked(replyToDiffReviewComment).mockResolvedValue(commentsPayload([
      comment({ id: 2, parent_id: 1, body: "Fixed in the follow-up commit." })
    ]))

    renderWorkspace()

    await screen.findAllByText("Please add a regression spec.")
    fireEvent.click(screen.getAllByRole("button", { name: "Reply" })[0])
    fireEvent.change(screen.getByLabelText("Reply"), { target: { value: "Fixed in the follow-up commit." } })
    fireEvent.click(screen.getByRole("button", { name: "Send reply" }))

    await waitFor(() => {
      expect(replyToDiffReviewComment).toHaveBeenCalledWith(42, 1, "Fixed in the follow-up commit.", 100)
    })
  })

  it("marks the source diff fetch as a diff_review.fetch_source_diff span", async () => {
    const measureAsyncSpy = vi.spyOn(performanceMarkers, "measureAsync")
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await waitFor(() => expect(measureAsyncSpy).toHaveBeenCalledWith(
      "diff_review.fetch_source_diff",
      expect.any(Function),
      expect.objectContaining({ metadata: { job_id: 42 } })
    ))
    vi.restoreAllMocks()
  })

  it("marks the initial diff render once the source diff has loaded", async () => {
    const useMarkedRenderSpy = vi.spyOn(performanceMarkers, "useMarkedRender")
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await waitFor(() => expect(useMarkedRenderSpy).toHaveBeenCalledWith(
      "diff_review.initial_render",
      expect.objectContaining({ enabled: undefined, metadata: { total_files: sourceDiffPayload().files.length }, phase: "paint" })
    ))
    vi.restoreAllMocks()
  })

  it("renders a structured version range picker with aligned endpoint buttons and compact row metadata", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      versions: [
        version({ id: 100, version_index: 1, label: "Initial implementation", comments_count: 1, created_at: "2026-05-01T12:00:00Z" }),
        version({
          id: 200,
          version_index: 2,
          label: "v2 repair range",
          reason: "chat_feedback",
          trigger_kind: "chat_feedback",
          workflow_id: 12,
          run_id: 34,
          comments_count: 2,
          created_at: "2026-05-02T12:00:00Z",
          base_ref: "refs/heads/main-with-a-very-long-name",
          base_sha: "base-sha-1234567890",
          head_ref: "syrus/direct-42-with-a-very-long-branch-name",
          head_sha: "head-sha-1234567890"
        })
      ],
      version: version({
        id: 200,
        version_index: 2,
        label: "v2 repair range",
        reason: "chat_feedback",
        trigger_kind: "chat_feedback",
        workflow_id: 12,
        run_id: 34,
        comments_count: 2,
        created_at: "2026-05-02T12:00:00Z",
        base_ref: "refs/heads/main-with-a-very-long-name",
        base_sha: "base-sha-1234567890",
        head_ref: "syrus/direct-42-with-a-very-long-branch-name",
        head_sha: "head-sha-1234567890"
      })
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    expect(selector).toHaveRole("button")
    expect(selector).toHaveTextContent("v2 repair range")
    expect(selector).toHaveAttribute("aria-haspopup", "listbox")
    expect(selector).toHaveAttribute("aria-expanded", "false")
    expect(selector.closest("div")).toHaveClass("w-full", "min-w-0", "max-w-full")

    fireEvent.click(selector)

    expect(selector).toHaveAttribute("aria-expanded", "true")
    const listbox = screen.getByRole("listbox", { name: "Version" })
    expect(listbox).toHaveClass("max-h-[min(22rem,70vh)]", "w-[min(100%,calc(100vw-2rem))]", "overflow-y-auto")
    const selectedRange = within(listbox).getByRole("option", { name: /v2 repair range - From refs\/heads\/main-with-a-very-long-name \(base-sh\) to syrus\/direct-42-with-a-very-long-branch-name \(head-sh\)/ })
    expect(selectedRange).toHaveAttribute("aria-selected", "true")
    const endpointButtons = within(selectedRange).getAllByRole("button")
    expect(endpointButtons[0]).toHaveAccessibleName("From v2 RUN-34")
    expect(endpointButtons[0]).toHaveClass("w-16", "border-brand")
    expect(endpointButtons[1]).toHaveAccessibleName("To v2 RUN-34")
    expect(endpointButtons[1]).toHaveClass("w-16", "border-brand")
    expect(within(selectedRange).getByRole("button", { name: "v2 RUN-34" })).toHaveAttribute(
      "title",
      expect.stringMatching(/v2 - WF-12 - RUN-34 - .* - 2 files - 2 comments - From refs\/heads\/main-with-a-very-long-name/)
    )
    expect(within(selectedRange).queryByText("refs/hea...ong-name")).not.toBeInTheDocument()
    expect(screen.getByTitle("refs/heads/main-with-a-very-long-name @ base-sha-1234567890")).toHaveTextContent("From")
    expect(screen.getByTitle("syrus/direct-42-with-a-very-long-branch-name @ head-sha-1234567890")).toHaveTextContent("To")
    expect(screen.getByText(/Latest - chat_feedback - Workflow 12, Run 34 - .* - From refs\/heads\/main-with-a-very-long-name \(base-sh\) to syrus\/direct-42-with-a-very-long-branch-name \(head-sh\) - 2 files - 2 comments/)).toBeInTheDocument()
  })

  it("defaults to All changes while keeping a smaller repair-step range selectable", async () => {
    const latest = sourceDiffPayload({
      version: version({ id: 200, version_index: 2, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } }),
      versions: [
        version({ id: 100, version_index: 1, base_sha: "initial-head", head_sha: "branch-head", label: "Initial implementation", run_id: 34, files_count: 1 }),
        version({ id: 200, version_index: 2, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" }, files_count: 2 })
      ],
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(latest)
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...version({ id: 100, version_index: 1, base_sha: "initial-head", head_sha: "branch-head", label: "Initial implementation", run_id: 34, files_count: 1 }),
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: [{
        additions: 1,
        deletions: 0,
        path: "db/migrate/repair.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+repair-only"
      }]
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    expect(selector).toHaveRole("button")
    expect(selector).toHaveTextContent("All changes")
    expect(screen.getByTitle("app/models/all_changes.rb")).toBeInTheDocument()

    fireEvent.click(selector)
    const listbox = screen.getByRole("listbox", { name: "Version" })
    expect(within(listbox).getAllByRole("option")[0]).toHaveTextContent("All changes")
    const allChanges = within(listbox).getByRole("option", { name: /All changes - From main \(branch-\) to syrus\/issue-42 \(branch-\)/ })
    expect(allChanges).toHaveAttribute("aria-selected", "true")
    expect(within(allChanges).queryByText("From")).not.toBeInTheDocument()
    expect(within(allChanges).queryByText("To")).not.toBeInTheDocument()

    const initialRange = within(listbox).getByRole("option", { name: /Initial implementation - From main \(initial\) to syrus\/issue-42 \(branch-\)/ })
    fireEvent.click(within(initialRange).getByRole("button", { name: "v1 RUN-34" }))

    expect(await screen.findByTitle("db/migrate/repair.rb")).toBeInTheDocument()
    expect(fetchDiffReviewVersion).toHaveBeenCalledWith(42, 100)
    expect(screen.queryByText("all-changes")).not.toBeInTheDocument()
  })

  it("selects independent From and To endpoints as an explicit review range", async () => {
    const initial = sourceDiffPayload({
      version: version({ id: 300, version_index: 3, base_sha: "branch-base", head_sha: "third-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } }),
      versions: [
        version({ id: 100, version_index: 1, base_sha: "branch-base", head_sha: "first-head", label: "Initial implementation", run_id: 11 }),
        version({ id: 200, version_index: 2, base_sha: "first-head", head_sha: "second-head", label: "Repair", run_id: 22 }),
        version({ id: 300, version_index: 3, base_sha: "branch-base", head_sha: "third-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } })
      ],
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    const explicit = sourceDiffPayload({
      version: version({ id: 400, version_index: 4, base_sha: "first-head", head_sha: "third-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions: initial.versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/custom_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+custom-range"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValueOnce(initial).mockResolvedValueOnce(explicit)
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 300))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    const listbox = screen.getByRole("listbox", { name: "Version" })
    const repairRange = within(listbox).getByRole("option", { name: /Repair - From main \(first-h\) to syrus\/issue-42 \(second-\)/ })
    fireEvent.click(within(repairRange).getByRole("button", { name: "From v2 RUN-22" }))

    expect(await screen.findByTitle("app/models/custom_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=first-head&head=third-head")
  })

  it("does not keep the previous explicit range visible while a new range loads", async () => {
    const initial = sourceDiffPayload({
      version: version({ id: 500, version_index: 5, base_sha: "branch-base", head_sha: "fourth-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } }),
      versions: [
        version({ id: 100, version_index: 1, base_sha: "branch-base", head_sha: "first-head", label: "Initial implementation", run_id: 11 }),
        version({ id: 200, version_index: 2, base_sha: "first-head", head_sha: "second-head", label: "Repair", run_id: 22 }),
        version({ id: 300, version_index: 3, base_sha: "second-head", head_sha: "third-head", label: "Follow-up", run_id: 33 }),
        version({ id: 400, version_index: 4, base_sha: "third-head", head_sha: "fourth-head", label: "Final", run_id: 44 }),
        version({ id: 500, version_index: 5, base_sha: "branch-base", head_sha: "fourth-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } })
      ]
    })
    const firstExplicit = sourceDiffPayload({
      version: version({ id: 600, version_index: 6, base_sha: "first-head", head_sha: "fourth-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions: initial.versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/first_custom_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+first-custom-range"
      }]
    })
    let resolveSecondExplicit: (payload: JobSourceDiffPayload) => void = () => {}
    const secondExplicit = new Promise<JobSourceDiffPayload>((resolve) => {
      resolveSecondExplicit = resolve
    })
    vi.mocked(fetchJobSourceDiff)
      .mockResolvedValueOnce(initial)
      .mockResolvedValueOnce(firstExplicit)
      .mockReturnValueOnce(secondExplicit)
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 500))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "From v2 RUN-22" }))
    expect(await screen.findByTitle("app/models/first_custom_range.rb")).toBeInTheDocument()

    fireEvent.click(await screen.findByLabelText("Version"))
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "To v3 RUN-33" }))

    expect(screen.getByText("Loading diff...")).toBeInTheDocument()
    expect(screen.queryByTitle("app/models/first_custom_range.rb")).not.toBeInTheDocument()
    resolveSecondExplicit(sourceDiffPayload({
      version: version({ id: 700, version_index: 7, base_sha: "first-head", head_sha: "third-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions: initial.versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/second_custom_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+second-custom-range"
      }]
    }))
    expect(await screen.findByTitle("app/models/second_custom_range.rb")).toBeInTheDocument()
  })

  it("prefers the All changes full range even when the embedded payload version is a narrower range", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 100, version_index: 1, label: "Preview fixture", base_sha: "preview-base", head_sha: "preview-head" }),
      versions: [
        version({ id: 100, version_index: 1, label: "Preview fixture", base_sha: "preview-base", head_sha: "preview-head", files_count: 1 }),
        version({ id: 200, version_index: 2, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" }, files_count: 2 })
      ],
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/preview_fixture.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+preview-fixture"
      }]
    }))
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...version({ id: 200, version_index: 2, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" }, files_count: 2 }),
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 200))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    expect(selector).toHaveTextContent("All changes")
    expect(fetchDiffReviewVersion).toHaveBeenCalledWith(42, 200)
    expect(screen.getByTitle("app/models/all_changes.rb")).toBeInTheDocument()
    expect(screen.queryByTitle("app/models/preview_fixture.rb")).not.toBeInTheDocument()

    fireEvent.click(selector)
    expect(within(screen.getByRole("listbox", { name: "Version" })).getByRole("option", { name: /All changes - From main \(branch-\) to syrus\/issue-42 \(branch-\)/ })).toHaveAttribute("aria-selected", "true")
  })

  it("keeps latest-version review behavior working while comment history is enabled", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([comment({ id: 1 })]))
    vi.mocked(submitDiffReviewComments).mockResolvedValue({
      message: "Diff comments submitted as chat feedback.",
      workflow: { id: 7, trigger_kind: "chat_feedback", state: "queued" },
      comments: []
    })

    renderWorkspace()

    await screen.findByText("Please add a regression spec.")
    fireEvent.click(screen.getByRole("button", { name: "Submit feedback" }))

    await waitFor(() => {
      expect(fetchDiffReviewComments).toHaveBeenCalledWith(42, "?surface=job_review_workspace&all_versions=1")
      expect(submitDiffReviewComments).toHaveBeenCalledWith(42, [1], 100)
    })
  })

  it("shows old comments as historical and switches to their anchored diff line", async () => {
    const oldComment = comment({
      id: 10,
      diff_review_version_id: 100,
      diff_review_version: version({ id: 100, version_index: 1 }),
      new_line: 1,
      anchor_key: "right::1",
      body: "Old v1 note."
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 200, version_index: 2, label: "Chat feedback #1" }),
      versions: [
        version({ id: 100, version_index: 1, label: "Initial implementation", comments_count: 1 }),
        version({ id: 200, version_index: 2, label: "Chat feedback #1", comments_count: 0 })
      ]
    }))
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...version({ id: 100, version_index: 1, label: "Initial implementation" }),
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/user.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+new"
      }]
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([oldComment], 200))

    renderWorkspace()

    await screen.findByText("v1 historical")
    fireEvent.click(screen.getByRole("button", { name: "View in diff" }))

    await waitFor(() => expect(screen.getByLabelText("Version")).toHaveTextContent("Initial implementation"))
    expect(document.querySelector('[data-diff-anchor="right::1"]')).toBeInTheDocument()
    await waitFor(() => expect(HTMLElement.prototype.scrollIntoView).toHaveBeenCalled())
  })

  it("sends historical comment mutations with the comment's own version id", async () => {
    const oldComment = comment({
      id: 12,
      diff_review_version_id: 100,
      diff_review_version: version({ id: 100, version_index: 1 }),
      body: "Old comment needing a reply."
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 200, version_index: 2 }),
      versions: [version({ id: 100, version_index: 1, comments_count: 1 }), version({ id: 200, version_index: 2 })]
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([oldComment], 200))
    vi.mocked(replyToDiffReviewComment).mockResolvedValue(commentsPayload([
      comment({ id: 13, parent_id: 12, body: "Acknowledged." })
    ]))

    renderWorkspace()

    await screen.findByText("Old comment needing a reply.")
    fireEvent.click(screen.getByRole("button", { name: "Reply" }))
    fireEvent.change(screen.getByLabelText("Reply"), { target: { value: "Acknowledged." } })
    fireEvent.click(screen.getByRole("button", { name: "Send reply" }))

    await waitFor(() => {
      expect(replyToDiffReviewComment).toHaveBeenCalledWith(42, 12, "Acknowledged.", 100)
    })
  })

  it("switches whole-review old comments to their version and focuses the sidebar record", async () => {
    const oldComment = comment({
      id: 11,
      anchor_kind: "review",
      path: null,
      side: null,
      new_line: null,
      anchor_key: "review",
      diff_review_version_id: 100,
      diff_review_version: version({ id: 100, version_index: 1 }),
      body: "Old whole-review note."
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 200, version_index: 2 }),
      versions: [version({ id: 100, version_index: 1, comments_count: 1 }), version({ id: 200, version_index: 2 })]
    }))
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...version({ id: 100, version_index: 1 }),
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: sourceDiffPayload().files
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([oldComment], 200))

    renderWorkspace()

    await screen.findByText("Old whole-review note.")
    fireEvent.click(screen.getByRole("button", { name: "View in diff" }))

    await waitFor(() => expect(screen.getByLabelText("Version")).toHaveTextContent("Version 1"))
    const record = document.querySelector('[data-diff-review-comment-id="11"]') as HTMLElement
    expect(record).toBeInTheDocument()
    expect(HTMLElement.prototype.scrollIntoView).toHaveBeenCalled()
  })
})

function sourceDiffPayload(overrides: Partial<JobSourceDiffPayload> = {}): JobSourceDiffPayload {
  return {
    job_id: 42,
    base_ref: "base-sha",
    head_ref: "head-sha",
    merge_base_sha: "base-sha",
    default_ref: "main",
    branch_commits: [],
    truncated: false,
    diff_error: null,
    version: version(),
    versions: [
      version()
    ],
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
    ],
    ...overrides
  }
}

function version(overrides: Partial<NonNullable<JobSourceDiffPayload["version"]>> = {}): NonNullable<JobSourceDiffPayload["version"]> {
  return {
    id: 100,
    job_id: 42,
    version_index: 1,
    base_sha: "base-sha",
    head_sha: "head-sha",
    base_ref: "main",
    head_ref: "syrus/issue-42",
    workflow_id: null,
    workflow: null,
    run_id: null,
    trigger_kind: "initial",
    label: "Version 1",
    reason: "initial",
    truncated: false,
    files_count: 2,
    comments_count: 0,
    metadata: {},
    created_at: null,
    ...overrides
  }
}

function commentsPayload(comments: DiffReviewComment[], selectedVersionId = 100): DiffReviewCommentsPayload {
  return { job_id: 42, diff_review_version_id: selectedVersionId, latest_version_id: selectedVersionId, comments, by_path: {} }
}

function comment(overrides: Partial<DiffReviewComment> = {}): DiffReviewComment {
  return {
    id: 1,
    job_id: 42,
    diff_review_version_id: 100,
    diff_review_version: version(),
    parent_id: null,
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
