import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { AgentDiff, ReviewableDiff, filesFromUnifiedDiff } from "./ReviewableDiff"

const files = [
  {
    additions: 1,
    deletions: 1,
    patch: [
      "diff --git a/app/models/job.rb b/app/models/job.rb",
      "--- a/app/models/job.rb",
      "+++ b/app/models/job.rb",
      "@@ -1,2 +1,2 @@",
      "-old",
      "+new"
    ].join("\n"),
    path: "app/models/job.rb",
    status: "modified"
  },
  {
    additions: 1,
    deletions: 0,
    patch: [
      "diff --git a/app/models/run.rb b/app/models/run.rb",
      "--- a/app/models/run.rb",
      "+++ b/app/models/run.rb",
      "@@ -5,1 +5,2 @@",
      " context",
      "+added"
    ].join("\n"),
    path: "app/models/run.rb",
    status: "modified"
  }
]

describe("ReviewableDiff", () => {
  it("renders only the selected file in single-file mode", () => {
    render(<ReviewableDiff files={files} mode="single-file" selectedPath="app/models/run.rb" showFileHeaders />)

    expect(screen.queryByText("new")).not.toBeInTheDocument()
    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByTitle("app/models/run.rb")).toHaveClass("sticky")
  })

  it("renders every file with stable headers in continuous mode", () => {
    render(<ReviewableDiff files={files} mode="continuous" />)

    expect(screen.getByTitle("app/models/job.rb")).toHaveClass("sticky")
    expect(screen.getByTitle("app/models/run.rb")).toHaveClass("sticky")
    expect(screen.getByText("new")).toBeInTheDocument()
    expect(screen.getByText("added")).toBeInTheDocument()
  })

  it("keeps coverage annotations attached to new-line coordinates", () => {
    render(
      <ReviewableDiff
        annotations={{ "app/models/job.rb": { "1": "uncovered" } }}
        files={files}
        mode="single-file"
        selectedPath="app/models/job.rb"
      />
    )

    const row = screen.getByText("new").closest("tr")
    expect(row).toHaveAttribute("data-coverage", "uncovered")
    expect(within(row as HTMLElement).getByText("✗")).toBeInTheDocument()
  })

  it("exposes typed line selections for optional comment callbacks", () => {
    const onCommentLine = vi.fn()
    render(<ReviewableDiff files={files} mode="single-file" onCommentLine={onCommentLine} selectedPath="app/models/job.rb" />)

    fireEvent.click(screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" }))

    expect(onCommentLine).toHaveBeenCalledWith({
      file: files[0],
      line: expect.objectContaining({ code: "new", kind: "add", newLine: 1, oldLine: null }),
      side: "new"
    })
  })

  it("renders anchored diff review threads beside matching lines", () => {
    render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        files={files}
        mode="single-file"
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.getByTestId("diff-review-thread")).toHaveTextContent("Please cover this branch.")
    expect(screen.getByTestId("diff-review-thread")).toHaveTextContent("Ada")
  })

  it("edits a draft diff review thread inline instead of requiring a sidebar form", () => {
    const onStartEditThread = vi.fn()
    const onChangeEditingThreadBody = vi.fn()
    const onSaveEditThread = vi.fn()

    const { rerender } = render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        files={files}
        mode="single-file"
        onStartEditThread={onStartEditThread}
        selectedPath="app/models/job.rb"
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Edit" }))
    expect(onStartEditThread).toHaveBeenCalledWith({ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" })

    rerender(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        editingThreadBody="Please cover this branch and the error path."
        editingThreadId={1}
        files={files}
        mode="single-file"
        onChangeEditingThreadBody={onChangeEditingThreadBody}
        onSaveEditThread={onSaveEditThread}
        onStartEditThread={onStartEditThread}
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.getByLabelText("Edit comment 1")).toHaveValue("Please cover this branch and the error path.")
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(onSaveEditThread).toHaveBeenCalled()
  })

  it("replies to a diff review thread inline instead of requiring a sidebar form", () => {
    const onStartReplyThread = vi.fn()
    const onChangeReplyingThreadBody = vi.fn()
    const onSaveReplyThread = vi.fn()

    const { rerender } = render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "submitted" }]
          }
        }}
        files={files}
        mode="single-file"
        onStartReplyThread={onStartReplyThread}
        selectedPath="app/models/job.rb"
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Reply" }))
    expect(onStartReplyThread).toHaveBeenCalledWith({ id: 1, author: "Ada", body: "Please cover this branch.", state: "submitted" })

    rerender(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "submitted" }]
          }
        }}
        files={files}
        mode="single-file"
        onChangeReplyingThreadBody={onChangeReplyingThreadBody}
        onSaveReplyThread={onSaveReplyThread}
        onStartReplyThread={onStartReplyThread}
        replyingThreadBody="Agreed, adding a spec now."
        replyingThreadId={1}
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.getByLabelText("Reply to comment 1")).toHaveValue("Agreed, adding a spec now.")
    fireEvent.click(screen.getByRole("button", { name: "Post reply" }))
    expect(onSaveReplyThread).toHaveBeenCalled()
  })

  it("shows which comment a reply is replying to", () => {
    render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [
              { id: 1, author: "Ada", body: "Please cover this branch.", state: "submitted" },
              { id: 2, author: "Grace", body: "Adding a spec now.", parentId: 1, replyToAuthor: "Ada", state: "draft" }
            ]
          }
        }}
        files={files}
        mode="single-file"
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.getByText("Replying to Ada")).toBeInTheDocument()
  })

  it("bounds the diff height by default but grows naturally when scroll is set to natural", () => {
    const { rerender } = render(<ReviewableDiff files={files} mode="continuous" />)
    expect(screen.getByTestId("agent-diff-viewer").querySelector(".max-h-\\[32rem\\]")).toBeInTheDocument()

    rerender(<ReviewableDiff files={files} mode="continuous" scroll="natural" />)
    expect(screen.getByTestId("agent-diff-viewer").querySelector(".max-h-\\[32rem\\]")).not.toBeInTheDocument()
  })

  it("renders the add-comment affordance in the left gutter, not the right edge", () => {
    render(<ReviewableDiff files={files} mode="single-file" onCommentLine={vi.fn()} selectedPath="app/models/job.rb" />)

    const button = screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })
    const gutterCell = button.closest("td")
    const row = button.closest("tr")

    expect(gutterCell).not.toBeNull()
    expect(row?.querySelectorAll("td")[1]).toBe(gutterCell)
  })

  it("opens an on-demand popup listing changed files and navigates to the selected one", () => {
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" onSelectFile={vi.fn()} showFileHeaders />)

    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])

    expect(screen.getByText("Changed files")).toBeInTheDocument()
    const scrollSpy = vi.fn()
    const target = document.querySelector('[data-diff-file="app/models/run.rb"]') as HTMLElement
    target.scrollIntoView = scrollSpy

    fireEvent.click(screen.getByTitle("app/models/run.rb (+1 -0)"))

    expect(scrollSpy).toHaveBeenCalled()
    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
  })

  it("splits stored unified diffs into real changed files for anchored artifact review", () => {
    const diff = [
      "diff --git a/app/models/job.rb b/app/models/job.rb",
      "--- a/app/models/job.rb",
      "+++ b/app/models/job.rb",
      "@@ -1 +1 @@",
      "-old",
      "+new",
      "diff --git a/app/models/run.rb b/app/models/run.rb",
      "--- a/app/models/run.rb",
      "+++ b/app/models/run.rb",
      "@@ -4,0 +5 @@",
      "+added"
    ].join("\n")

    expect(filesFromUnifiedDiff(diff).map((file) => file.path)).toEqual(["app/models/job.rb", "app/models/run.rb"])

    render(<AgentDiff diff={diff} showFileHeaders />)

    expect(screen.getByTitle("app/models/job.rb")).toBeInTheDocument()
    expect(screen.getByTitle("app/models/run.rb")).toBeInTheDocument()
  })
})
