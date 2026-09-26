import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { stubVirtualizerMeasurements } from "../../test/virtualizerMeasurements"
import * as performanceMarkers from "../../lib/performanceMarkers"
import { DEFAULT_REVIEW_DIFF_SETTINGS, fetchReviewDiffSettings } from "../../api/reviewDiffSettings"
import { ShortcutsHelpModal } from "../../components/ShortcutsHelpModal"
import { ShortcutsProvider } from "../../contexts/ShortcutsContext"
import { ReviewWorkspace } from "./ReviewWorkspace"

stubVirtualizerMeasurements()
import {
  createDiffReviewComment,
  deleteDiffReviewComment,
  fetchDiffReviewVersion,
  fetchDiffReviewComments,
  fetchJobSourceDiff,
  replyToDiffReviewComment,
  startJobDiscussionChat,
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
    startJobDiscussionChat: vi.fn(),
    submitDiffReviewComments: vi.fn(),
    updateDiffReviewComment: vi.fn()
  }
})

vi.mock("../../api/reviewDiffSettings", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../api/reviewDiffSettings")>()
  return {
    ...actual,
    fetchReviewDiffSettings: vi.fn()
  }
})

beforeEach(() => {
  window.localStorage.clear()
  vi.useRealTimers()
  vi.mocked(createDiffReviewComment).mockReset()
  vi.mocked(deleteDiffReviewComment).mockReset()
  vi.mocked(fetchDiffReviewComments).mockReset()
  vi.mocked(fetchDiffReviewVersion).mockReset()
  vi.mocked(fetchJobSourceDiff).mockReset()
  vi.mocked(replyToDiffReviewComment).mockReset()
  vi.mocked(startJobDiscussionChat).mockReset()
  vi.mocked(submitDiffReviewComments).mockReset()
  vi.mocked(updateDiffReviewComment).mockReset()
  vi.mocked(fetchReviewDiffSettings).mockReset()
  vi.mocked(fetchReviewDiffSettings).mockResolvedValue({ review_diff_settings: DEFAULT_REVIEW_DIFF_SETTINGS })
  HTMLElement.prototype.scrollIntoView = vi.fn()
})

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
})

function renderWorkspace(payload = jobPayload()) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const result = render(
    <ShortcutsProvider>
      <QueryClientProvider client={client}>
        <ReviewWorkspace payload={payload} />
      </QueryClientProvider>
    </ShortcutsProvider>
  )
  return { client, ...result }
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

  it("applies global review diff settings in the main review workspace", async () => {
    vi.mocked(fetchReviewDiffSettings).mockResolvedValue({
      review_diff_settings: {
        ...DEFAULT_REVIEW_DIFF_SETTINGS,
        desktop_view: "split",
        file_list: false
      }
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Implementation review")
    expect(screen.queryByRole("button", { name: "Browse changed files" })).not.toBeInTheDocument()
    await waitFor(() => expect(document.querySelector('[data-diff-split-row="true"]')).toBeInTheDocument())
  })

  it("opens review settings from the main review workspace", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Review settings" }))

    const dialog = screen.getByRole("dialog", { name: "Review settings" })
    expect(dialog).toBeInTheDocument()
    expect(dialog).toHaveClass("max-h-[calc(100dvh-2rem)]", "overflow-y-auto")
    expect(screen.getByLabelText("Line wrapping")).toBeInTheDocument()
  })

  it("persists review diff shortcut changes and applies them to the visible diff immediately", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue({
      ok: true,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({
        review_diff_settings: {
          ...DEFAULT_REVIEW_DIFF_SETTINGS,
          line_wrapping: "wrap"
        }
      })
    } as Response)
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    const { client } = renderWorkspace()

    await screen.findByText("Implementation review")
    expect(screen.getAllByTestId("diff-file-scroll")[0]).toHaveClass("overflow-x-scroll")

    fireEvent.keyDown(window, { altKey: true, shiftKey: true, key: "W" })

    await waitFor(() => expect(screen.getAllByTestId("diff-file-scroll")[0]).toHaveClass("overflow-x-hidden"))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/review_diff_settings", expect.objectContaining({
      method: "PATCH",
      body: JSON.stringify({ review_diff_settings: { line_wrapping: "wrap" } })
    })))
    expect(client.getQueryData(["review_diff_settings"])).toMatchObject({
      review_diff_settings: expect.objectContaining({ line_wrapping: "wrap" })
    })
  })

  it("cycles split/unified view and exposes review shortcuts in the help modal", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue({
      ok: true,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({
        review_diff_settings: {
          ...DEFAULT_REVIEW_DIFF_SETTINGS,
          desktop_view: "split"
        }
      })
    } as Response)
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    function Harness({ helpOpen }: { helpOpen: boolean }) {
      return (
        <ShortcutsProvider>
          <QueryClientProvider client={client}>
            <ReviewWorkspace payload={jobPayload()} />
            <ShortcutsHelpModal onClose={() => {}} open={helpOpen} />
          </QueryClientProvider>
        </ShortcutsProvider>
      )
    }

    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    const { rerender } = render(<Harness helpOpen={false} />)

    await screen.findByText("Implementation review")
    fireEvent.keyDown(window, { altKey: true, shiftKey: true, key: "V" })

    await waitFor(() => expect(document.querySelector('[data-review-diff-view="split"]')).toBeInTheDocument())

    rerender(<Harness helpOpen />)

    const dialog = screen.getByRole("dialog", { name: "Keyboard shortcuts" })
    expect(within(dialog).getByText("Review diff")).toBeInTheDocument()
    expect(within(dialog).getByText("Toggle line wrapping")).toBeInTheDocument()
    expect(within(dialog).getByText("Cycle unified/split view")).toBeInTheDocument()
    expect(within(dialog).getByText("Toggle syntax highlighting")).toBeInTheDocument()
    expect(within(dialog).getByText("Cycle whitespace display")).toBeInTheDocument()
    expect(within(dialog).getByText("Alt + Shift + W")).toBeInTheDocument()
  })

  it("does not render a pending-feedback pill in the summary header", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const heading = await screen.findByText("Implementation review")
    const header = heading.closest("section") as HTMLElement
    expect(within(header).queryByText(/pending/i)).not.toBeInTheDocument()
  })

  it("never wraps the diff viewer in an ancestor with non-visible overflow, which would block its sticky file headers from pinning", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    const diffViewer = await screen.findByTestId("agent-diff-viewer")
    for (let ancestor = diffViewer.parentElement; ancestor && ancestor !== document.body; ancestor = ancestor.parentElement) {
      expect(ancestor.className).not.toMatch(/\boverflow-(hidden|auto|scroll|y-auto|y-scroll|x-auto|x-scroll)\b/)
    }
  })

  it("renders before/after image thumbnails for a patch-less image file instead of the generic placeholder", async () => {
    const payload = sourceDiffPayload()
    vi.mocked(fetchJobSourceDiff).mockResolvedValue({
      ...payload,
      files: [
        ...payload.files,
        { additions: 0, deletions: 0, is_image: true, patch: null, path: "app/assets/images/logo.png", status: "modified" }
      ]
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Implementation review")
    const beforeThumb = screen.getByRole("button", { name: "Open Before" })
    const afterThumb = screen.getByRole("button", { name: "Open After" })
    expect(beforeThumb.querySelector("img")).toHaveAttribute("src", "/api/v1/app/jobs/42/source_image?ref=base-sha&path=app%2Fassets%2Fimages%2Flogo.png")
    expect(afterThumb.querySelector("img")).toHaveAttribute("src", "/api/v1/app/jobs/42/source_image?ref=head-sha&path=app%2Fassets%2Fimages%2Flogo.png")
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

  it("labels a version-matched review artifact with version, workflow/run, trigger kind, iteration, and sha range", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace({
      ...jobPayload(),
      typed_artifacts: [
        {
          type: "visual_review_screenshot_run_5_1",
          title: "Homepage after fix",
          payload: { image_url: "https://example.test/a.png", iteration: 2 },
          created_at: "2026-01-01T00:00:00Z",
          renderer_type: "image_diff",
          workflow_id: 12,
          run_id: 5,
          step_id: 55,
          trigger_kind: "chat_feedback",
          base_sha: "abcdef1234567",
          head_sha: "head-sha",
          diff_review_version_id: 100
        }
      ]
    })

    await screen.findByText("Review artifacts")
    fireEvent.click(screen.getByRole("button", { name: "Show" }))

    expect(screen.getByText("Homepage after fix")).toBeInTheDocument()
    const provenance = screen.getByText(/Workflow 12/)
    expect(provenance).toHaveTextContent("Version 1")
    expect(provenance).toHaveTextContent("Workflow 12")
    expect(provenance).toHaveTextContent("Run 5")
    expect(provenance).toHaveTextContent("chat_feedback")
    expect(provenance).toHaveTextContent("Iteration 2")
    expect(provenance).toHaveTextContent("abcdef1 → head-sh")
    expect(screen.queryByText("Unversioned")).not.toBeInTheDocument()
  })

  it("shows a provenance-less artifact as unversioned instead of hiding it", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace({
      ...jobPayload(),
      typed_artifacts: [
        {
          type: "rails_schema_erd",
          title: "Schema ERD",
          payload: { tables: [] },
          created_at: "2026-01-01T00:00:00Z",
          renderer_type: "erd_diagram"
        }
      ]
    })

    await screen.findByText("Review artifacts")
    fireEvent.click(screen.getByRole("button", { name: "Show" }))

    expect(screen.getByText("Schema ERD")).toBeInTheDocument()
    expect(screen.getByText("Unversioned")).toBeInTheDocument()
  })

  it("filters out artifacts tied to a different diff review version while keeping unversioned ones visible", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 100 }),
      versions: [ version({ id: 100 }), version({ id: 200, version_index: 2, label: "Chat feedback #1" }) ]
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace({
      ...jobPayload(),
      typed_artifacts: [
        {
          type: "visual_review_screenshot_run_5_1",
          title: "Matches selected version",
          payload: {},
          created_at: "2026-01-01T00:00:00Z",
          renderer_type: "image_diff",
          run_id: 5,
          head_sha: "head-sha",
          diff_review_version_id: 100
        },
        {
          type: "visual_review_screenshot_run_9_1",
          title: "From a later round",
          payload: {},
          created_at: "2026-01-02T00:00:00Z",
          renderer_type: "image_diff",
          run_id: 9,
          head_sha: "other-head-sha",
          diff_review_version_id: 200
        },
        {
          type: "rails_schema_erd",
          title: "No provenance at all",
          payload: {},
          created_at: "2026-01-03T00:00:00Z",
          renderer_type: "erd_diagram"
        }
      ]
    })

    await screen.findByText("Review artifacts")
    fireEvent.click(screen.getByRole("button", { name: "Show" }))

    expect(screen.getByText("Matches selected version")).toBeInTheDocument()
    expect(screen.getByText("No provenance at all")).toBeInTheDocument()
    expect(screen.queryByText("From a later round")).not.toBeInTheDocument()
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

  it("renders the comments splitter expanded at the previous default width", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Diff comments")
    expect(screen.getByRole("separator", { name: "Resize diff comments" })).toHaveAttribute("aria-valuenow", "384")
    expect(screen.getByTestId("review-comments-panel")).toHaveStyle({ width: "384px" })
    expect(screen.queryByTestId("review-comments-rail")).not.toBeInTheDocument()
  })

  it("collapses and reopens the comments panel with a splitter click and remembers the preference", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Diff comments")
    const separator = screen.getByRole("separator", { name: "Resize diff comments" })

    fireEvent.click(separator)

    expect(screen.getByTestId("review-comments-panel")).toHaveClass("hidden")
    expect(screen.getByTestId("review-comments-rail")).toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.review.comments.collapsed")).toBe("true")

    fireEvent.click(separator)

    expect(screen.getByTestId("review-comments-panel")).not.toHaveClass("hidden")
    expect(screen.queryByTestId("review-comments-rail")).not.toBeInTheDocument()
    expect(window.localStorage.getItem("syrus.review.comments.collapsed")).toBe("false")
  })

  it("restores a persisted custom comments width", async () => {
    window.localStorage.setItem("syrus.review.comments.width", "512")
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Diff comments")
    expect(screen.getByTestId("review-comments-panel")).toHaveStyle({ width: "512px" })
    expect(screen.getByRole("separator", { name: "Resize diff comments" })).toHaveAttribute("aria-valuenow", "512")
  })

  it("resizes from the splitter and snaps the comments panel collapsed below the threshold", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))

    renderWorkspace()

    await screen.findByText("Diff comments")
    const separator = screen.getByRole("separator", { name: "Resize diff comments" })

    fireEvent.mouseDown(separator, { clientX: 1000 })
    fireEvent.mouseMove(window, { clientX: 900 })
    fireEvent.mouseUp(window, { clientX: 900 })

    expect(screen.getByTestId("review-comments-panel")).toHaveStyle({ width: "484px" })
    expect(window.localStorage.getItem("syrus.review.comments.width")).toBe("484")

    fireEvent.mouseDown(separator, { clientX: 900 })
    fireEvent.mouseMove(window, { clientX: 1200 })
    fireEvent.mouseUp(window, { clientX: 1200 })

    expect(screen.getByTestId("review-comments-panel")).toHaveClass("hidden")
    expect(window.localStorage.getItem("syrus.review.comments.collapsed")).toBe("true")
  })

  it("shows collapsed rail badges only for versions with comments and peeks the panel on hover", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 300, version_index: 3, label: null }),
      versions: [
        version({ id: 100, version_index: 1, label: null }),
        version({ id: 200, version_index: 2, label: null }),
        version({ id: 300, version_index: 3, label: null })
      ]
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([
      comment({ id: 1, diff_review_version_id: 100, diff_review_version: version({ id: 100, version_index: 1, label: null }) }),
      comment({ id: 2, diff_review_version_id: 200, diff_review_version: version({ id: 200, version_index: 2, label: null }), body: "Comment on v2." }),
      comment({ id: 3, diff_review_version_id: 200, diff_review_version: version({ id: 200, version_index: 2, label: null }), body: "Another comment on v2." })
    ], 300))

    renderWorkspace()

    await screen.findByText("Diff comments")
    vi.useFakeTimers()
    fireEvent.click(screen.getByRole("separator", { name: "Resize diff comments" }))

    const rail = screen.getByTestId("review-comments-rail")
    expect(within(rail).getByText("v1")).toBeInTheDocument()
    expect(within(rail).getByText("1")).toBeInTheDocument()
    expect(within(rail).getByText("v2")).toBeInTheDocument()
    expect(within(rail).getByText("2")).toBeInTheDocument()
    expect(within(rail).queryByText("v3")).not.toBeInTheDocument()
    expect(screen.queryByTestId("review-comments-peek")).not.toBeInTheDocument()

    fireEvent.mouseEnter(rail)
    act(() => vi.advanceTimersByTime(349))
    expect(screen.queryByTestId("review-comments-peek")).not.toBeInTheDocument()

    act(() => vi.advanceTimersByTime(1))
    expect(screen.getByTestId("review-comments-peek")).toBeInTheDocument()
    expect(within(screen.getByTestId("review-comments-peek")).getByText("Comment on v2.")).toBeInTheDocument()
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

  it("does not default to an empty legacy All changes version when real versions exist", async () => {
    const emptyAllChanges = version({
      id: 100,
      version_index: 1,
      base_sha: "main",
      head_sha: "main",
      label: "All changes",
      reason: "source_diff",
      metadata: { range_kind: "all_changes" },
      files_count: 0
    })
    const implementationVersion = version({
      id: 200,
      version_index: 2,
      base_sha: "impl-base",
      head_sha: "impl-head",
      label: "Initial implementation",
      reason: "initial",
      run_id: 34,
      files_count: 43
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: null,
      versions: [ emptyAllChanges, implementationVersion ],
      files: []
    }))
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...implementationVersion,
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: [{
        additions: 0,
        deletions: 19,
        path: "CLAUDE.md",
        status: "modified",
        patch: "@@ -1,2 +1 @@\n-old\n-new"
      }]
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 200))

    renderWorkspace()

    expect(await screen.findByTitle("CLAUDE.md")).toBeInTheDocument()
    expect(fetchDiffReviewVersion).toHaveBeenCalledWith(42, 200)
    expect(screen.queryByText("No changed files found.")).not.toBeInTheDocument()
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

  it("keeps a FROM/TO endpoint pick as an explicit range even when it coincides with a stored version's own base/head", async () => {
    // Regression: the default selection is "All changes" (v1's base to v4's
    // head). Picking FROM v1 while TO is still at its fallback computes
    // exactly that same base/head pair, which used to opportunistically
    // collapse back to re-selecting "All changes" -- silently discarding the
    // operator's FROM click instead of entering range mode.
    const versions = orderedRangeVersions()
    const initial = sourceDiffPayload({
      version: versions[4],
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    const explicitRange = sourceDiffPayload({
      version: version({ id: 600, version_index: 6, base_sha: "branch-base", head_sha: "fourth-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/from_click_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+from-click-range"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValueOnce(initial).mockResolvedValueOnce(explicitRange)
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 500))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "From v1 RUN-11" }))

    expect(await screen.findByTitle("app/models/from_click_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=branch-base&head=fourth-head")
    expect(fetchDiffReviewVersion).not.toHaveBeenCalled()
  })

  it("shows one canonical row when persisted versions duplicate the same run range", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 700, version_index: 7, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } }),
      versions: [
        version({ id: 500, version_index: 5, base_sha: "old-base", head_sha: "old-head", label: "Run-scoped range", run_id: 321 }),
        version({ id: 600, version_index: 6, base_sha: "old-base", head_sha: "old-head", label: "Run-scoped range", run_id: 321 }),
        version({ id: 700, version_index: 7, base_sha: "branch-base", head_sha: "branch-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } })
      ]
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 700))

    renderWorkspace()

    fireEvent.click(await screen.findByLabelText("Version"))
    const listbox = screen.getByRole("listbox", { name: "Version" })

    expect(within(listbox).getByRole("button", { name: "v5 RUN-321" })).toBeInTheDocument()
    expect(within(listbox).queryByRole("button", { name: "v6 RUN-321" })).not.toBeInTheDocument()
  })

  it("clamps From endpoint selections so From cannot be newer than To", async () => {
    const versions = orderedRangeVersions()
    const initial = sourceDiffPayload({
      version: versions[4],
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    const firstRange = sourceDiffPayload({
      version: version({ id: 600, version_index: 6, base_sha: "branch-base", head_sha: "second-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/first_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+first-range"
      }]
    })
    const clampedRange = sourceDiffPayload({
      version: version({ id: 700, version_index: 7, base_sha: "third-head", head_sha: "fourth-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/fourth_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+fourth-range"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValueOnce(initial).mockResolvedValueOnce(firstRange).mockResolvedValueOnce(clampedRange)
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 500))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "To v2 RUN-22" }))
    expect(await screen.findByTitle("app/models/first_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=branch-base&head=second-head")

    fireEvent.click(await screen.findByLabelText("Version"))
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "From v4 RUN-44" }))

    // FROM v4 is newer than the current TO (v2), so it clamps TO forward to
    // v4's own head instead of producing an invalid inverted range -- the
    // clamp still lands on an explicit range request, never a single-version
    // fetch that would discard which endpoint the operator actually picked.
    expect(await screen.findByTitle("app/models/fourth_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=third-head&head=fourth-head")
    expect(fetchDiffReviewVersion).not.toHaveBeenCalled()
    expect(fetchJobSourceDiff).not.toHaveBeenCalledWith("42", "?base=third-head&head=second-head")
  })

  it("clamps To endpoint selections so To cannot be older than From", async () => {
    const versions = orderedRangeVersions()
    const initial = sourceDiffPayload({
      version: versions[4],
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/all_changes.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+all-changes"
      }]
    })
    const firstRange = sourceDiffPayload({
      version: version({ id: 600, version_index: 6, base_sha: "second-head", head_sha: "fourth-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/first_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+first-range"
      }]
    })
    const clampedRange = sourceDiffPayload({
      version: version({ id: 700, version_index: 7, base_sha: "first-head", head_sha: "second-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/second_range.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+second-range"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValueOnce(initial).mockResolvedValueOnce(firstRange).mockResolvedValueOnce(clampedRange)
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([], 500))

    renderWorkspace()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "From v3 RUN-33" }))
    expect(await screen.findByTitle("app/models/first_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=second-head&head=fourth-head")

    fireEvent.click(await screen.findByLabelText("Version"))
    fireEvent.click(within(screen.getByRole("listbox", { name: "Version" })).getByRole("button", { name: "To v2 RUN-22" }))

    // TO v2 is older than the current FROM (v3), so it clamps FROM back to
    // v2's own base instead of producing an invalid inverted range -- the
    // clamp still lands on an explicit range request, never a single-version
    // fetch that would discard which endpoint the operator actually picked.
    expect(await screen.findByTitle("app/models/second_range.rb")).toBeInTheDocument()
    expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=first-head&head=second-head")
    expect(fetchDiffReviewVersion).not.toHaveBeenCalled()
    expect(fetchJobSourceDiff).not.toHaveBeenCalledWith("42", "?base=second-head&head=second-head")
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

  it("starts a discussion chat from the diff comment composer", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(startJobDiscussionChat).mockReturnValue(new Promise(() => {}))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Comment on app/models/user.rb:new:1" }))

    const composer = screen.getByTestId("diff-review-composer")
    fireEvent.change(within(composer).getByLabelText("Comment"), { target: { value: "Please add a regression spec." } })
    fireEvent.click(within(composer).getByRole("button", { name: "Discuss" }))

    await waitFor(() => {
      expect(startJobDiscussionChat).toHaveBeenCalledWith(42, [
        "Discuss this code review comment.",
        "Revision: head-sha",
        "Location: app/models/user.rb:1",
        "",
        "Comment:",
        "Please add a regression spec."
      ].join("\n"))
    })

    // Still pending (the mock never resolves) -- the composer stays put showing
    // the in-flight state rather than disappearing before we know it worked.
    expect(within(composer).getByRole("button", { name: "Starting..." })).toBeDisabled()
  })

  it("keeps the draft and shows an error in the composer when starting a discussion chat fails", async () => {
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload())
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([]))
    vi.mocked(startJobDiscussionChat).mockRejectedValue(new Error("boom"))

    renderWorkspace()

    fireEvent.click(await screen.findByRole("button", { name: "Comment on app/models/user.rb:new:1" }))

    const composer = screen.getByTestId("diff-review-composer")
    fireEvent.change(within(composer).getByLabelText("Comment"), { target: { value: "Please add a regression spec." } })
    fireEvent.click(within(composer).getByRole("button", { name: "Discuss" }))

    await within(composer).findByText("Unable to start discussion.")

    // The draft survives the failure so the user can retry instead of losing it.
    expect(within(composer).getByLabelText("Comment")).toHaveValue("Please add a regression spec.")
    expect(createDiffReviewComment).not.toHaveBeenCalled()
  })

  it("groups old comments under their own version section, keeps them out of the current diff, and switches to their anchored diff line", async () => {
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

    await screen.findByText("Initial implementation")
    expect(screen.queryByTestId("diff-review-thread")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "View in diff" }))

    await waitFor(() => expect(screen.getByLabelText("Version")).toHaveTextContent("Initial implementation"))
    expect(document.querySelector('[data-diff-anchor="right::1"]')).toBeInTheDocument()
    expect(await screen.findByTestId("diff-review-thread")).toBeInTheDocument()
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

  it("keeps a comment from another version out of a multi-version range's inline diff, grouped in the sidebar instead", async () => {
    const rangeVersions = [
      version({ id: 100, version_index: 1, base_sha: "branch-base", head_sha: "first-head", label: "Initial implementation", run_id: 11 }),
      version({ id: 200, version_index: 2, base_sha: "first-head", head_sha: "second-head", label: "Repair", run_id: 22 }),
      version({ id: 300, version_index: 3, base_sha: "branch-base", head_sha: "third-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } })
    ]
    const initial = sourceDiffPayload({
      version: rangeVersions[2],
      versions: rangeVersions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/shared.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+shared"
      }]
    })
    const range = sourceDiffPayload({
      version: version({ id: 400, version_index: 4, base_sha: "first-head", head_sha: "third-head", label: null, reason: "source_diff_selection", metadata: { range_kind: "explicit_selection" } }),
      versions: rangeVersions,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/shared.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+shared"
      }]
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValueOnce(initial).mockResolvedValueOnce(range)
    const oldComment = comment({
      id: 20,
      diff_review_version_id: 100,
      diff_review_version: version({ id: 100, version_index: 1, label: "Initial implementation", run_id: 11 }),
      path: "app/models/shared.rb",
      new_line: 1,
      anchor_key: "right::1",
      body: "Comment anchored to the initial implementation version."
    })
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([oldComment], 300))
    vi.mocked(fetchDiffReviewVersion).mockResolvedValue({
      ...version({ id: 100, version_index: 1, label: "Initial implementation", run_id: 11 }),
      job_id: 42,
      default_ref: "main",
      diff_error: null,
      files: [{
        additions: 1,
        deletions: 0,
        path: "app/models/shared.rb",
        status: "modified",
        patch: "@@ -1 +1 @@\n+shared"
      }]
    })

    renderWorkspace()

    await screen.findByText("Comment anchored to the initial implementation version.")
    expect(screen.queryByTestId("diff-review-thread")).not.toBeInTheDocument()

    const selector = await screen.findByLabelText("Version")
    fireEvent.click(selector)
    const listbox = screen.getByRole("listbox", { name: "Version" })
    const repairRange = within(listbox).getByRole("option", { name: /Repair - From main \(first-h\) to syrus\/issue-42 \(second-\)/ })
    fireEvent.click(within(repairRange).getByRole("button", { name: "From v2 RUN-22" }))

    await waitFor(() => expect(fetchJobSourceDiff).toHaveBeenLastCalledWith("42", "?base=first-head&head=third-head"))
    expect(await screen.findByTitle("app/models/shared.rb")).toBeInTheDocument()
    // The range (v2's base .. All changes' head) is a brand new persisted
    // version distinct from the comment's own v1 -- it must never render
    // inline just because the file/line happens to coincide.
    expect(screen.queryByTestId("diff-review-thread")).not.toBeInTheDocument()
    expect(screen.getByText("Comment anchored to the initial implementation version.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "View in diff" }))

    await waitFor(() => expect(screen.getByLabelText("Version")).toHaveTextContent("Initial implementation"))
    expect(document.querySelector('[data-diff-anchor="right::1"]')).toBeInTheDocument()
    expect(await screen.findByTestId("diff-review-thread")).toBeInTheDocument()
  })

  it("orders sidebar comment sections by version_index and marks only the currently displayed version", async () => {
    const currentComment = comment({
      id: 30,
      diff_review_version_id: 200,
      diff_review_version: version({ id: 200, version_index: 2, label: "Repair", run_id: 22 }),
      body: "Comment on the current version."
    })
    const oldComment = comment({
      id: 31,
      diff_review_version_id: 100,
      diff_review_version: version({ id: 100, version_index: 1, label: "Initial implementation", run_id: 11 }),
      body: "Comment on an earlier version."
    })
    vi.mocked(fetchJobSourceDiff).mockResolvedValue(sourceDiffPayload({
      version: version({ id: 200, version_index: 2, label: "Repair", run_id: 22 }),
      versions: [
        version({ id: 100, version_index: 1, label: "Initial implementation", run_id: 11, comments_count: 1 }),
        version({ id: 200, version_index: 2, label: "Repair", run_id: 22, comments_count: 1 })
      ]
    }))
    vi.mocked(fetchDiffReviewComments).mockResolvedValue(commentsPayload([oldComment, currentComment], 200))

    renderWorkspace()

    await screen.findByText("Comment on the current version.")
    const sidebar = screen.getByText("Diff comments").closest("section") as HTMLElement
    expect(within(sidebar).getByText("Comment on an earlier version.")).toBeInTheDocument()

    const sidebarText = sidebar.textContent || ""
    expect(sidebarText.indexOf("Initial implementation")).toBeLessThan(sidebarText.indexOf("Repair"))
    expect(within(sidebar).getAllByText("Currently viewing")).toHaveLength(1)
  })
})

function sourceDiffPayload(overrides: Partial<JobSourceDiffPayload> = {}): JobSourceDiffPayload {
  return {
    job_id: 42,
    base_ref: "base-sha",
    head_ref: "head-sha",
    base_sha: "base-sha",
    head_sha: "head-sha",
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

function orderedRangeVersions(): NonNullable<JobSourceDiffPayload["version"]>[] {
  return [
    version({ id: 100, version_index: 1, base_sha: "branch-base", head_sha: "first-head", label: "Initial implementation", run_id: 11 }),
    version({ id: 200, version_index: 2, base_sha: "first-head", head_sha: "second-head", label: "Repair", run_id: 22 }),
    version({ id: 300, version_index: 3, base_sha: "second-head", head_sha: "third-head", label: "Follow-up", run_id: 33 }),
    version({ id: 400, version_index: 4, base_sha: "third-head", head_sha: "fourth-head", label: "Final", run_id: 44 }),
    version({ id: 500, version_index: 5, base_sha: "branch-base", head_sha: "fourth-head", label: "All changes", reason: "source_diff", metadata: { range_kind: "all_changes" } })
  ]
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
