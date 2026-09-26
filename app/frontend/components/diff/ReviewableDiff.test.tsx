import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { useState } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { stubVirtualizerMeasurements } from "../../test/virtualizerMeasurements"
import * as highlighterLib from "../../lib/highlighter"
import * as performanceMarkers from "../../lib/performanceMarkers"
import { DEFAULT_REVIEW_DIFF_SETTINGS } from "../../api/reviewDiffSettings"
import { AgentDiff, DiffHunkSnippet, ReviewableDiff, annotationsForFile, filesFromUnifiedDiff, isLineAnnotations } from "./ReviewableDiff"

stubVirtualizerMeasurements()

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

// Word highlighting wraps each token in its own <span>, so a multi-token
// line's text is spread across siblings and getByText's default (which only
// looks at an element's direct text-node children) can't find it as one
// string. Match on the code cell's full textContent instead.
function findCodeCellText(text: string) {
  return screen.findByText((_, element) => Boolean(element && element.tagName === "TD" && element.textContent === text))
}
function getCodeCellText(text: string) {
  return screen.getByText((_, element) => Boolean(element && element.tagName === "TD" && element.textContent === text))
}

function getCodeToken(text: string) {
  return within(getCodeCellText(text)).getByText(text)
}

function manyFiles(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    additions: 1,
    deletions: 0,
    patch: [
      `diff --git a/file${index}.rb b/file${index}.rb`,
      `--- a/file${index}.rb`,
      `+++ b/file${index}.rb`,
      "@@ -1,1 +1,2 @@",
      " keep",
      "+added"
    ].join("\n"),
    path: `file${index}.rb`,
    status: "modified"
  }))
}

function wideLineFile() {
  const wideToken = "x".repeat(240)
  return {
    additions: 1,
    deletions: 0,
    patch: [
      "diff --git a/app/models/wide.rb b/app/models/wide.rb",
      "--- a/app/models/wide.rb",
      "+++ b/app/models/wide.rb",
      "@@ -1,1 +1,2 @@",
      " keep",
      `+${wideToken}`
    ].join("\n"),
    path: "app/models/wide.rb",
    status: "modified"
  }
}

function splitWideLineFile() {
  const wideToken = "new_value_".repeat(40)
  return {
    additions: 1,
    deletions: 1,
    patch: [
      "diff --git a/app/models/split.rb b/app/models/split.rb",
      "--- a/app/models/split.rb",
      "+++ b/app/models/split.rb",
      "@@ -1,2 +1,2 @@",
      "-short_old_value",
      `+${wideToken}`
    ].join("\n"),
    path: "app/models/split.rb",
    status: "modified"
  }
}

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

  it("applies persisted review rendering settings", () => {
    render(<ReviewableDiff files={files} mode="continuous" reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, desktop_view: "split", line_wrapping: "scroll", line_numbers: false, tab_width: 4, density: "compact", intraline_highlighting: "off" }} showFileHeaders />)

    const table = screen.getAllByRole("table")[0]
    expect(table).toHaveAttribute("data-review-diff-view", "split")
    expect(table).toHaveStyle({ tabSize: "4" })
    expect(table.querySelector('[data-diff-split-row="true"] [data-diff-split-side="old"]')).toHaveTextContent("old")
    expect(table.querySelector('[data-diff-split-row="true"] [data-diff-split-side="new"]')).toHaveTextContent("")
    expect(screen.getAllByTestId("diff-file-scroll")[0]).toHaveClass("overflow-x-scroll")
  })

  it("keeps compact density visibly denser than comfortable across diff rows, headers, and file lists", () => {
    const compactSettings = { ...DEFAULT_REVIEW_DIFF_SETTINGS, density: "compact" as const }
    const comfortableSettings = { ...DEFAULT_REVIEW_DIFF_SETTINGS, density: "comfortable" as const }
    const { rerender } = render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" onCommentLine={vi.fn()} reviewSettings={compactSettings} showFileHeaders />)

    expect(screen.getAllByRole("table")[0]).toHaveClass("text-2xs")
    expect(getCodeCellText("new")).toHaveClass("py-0", "leading-[14px]")
    expect(getCodeCellText("new")).not.toHaveClass("py-0.5")
    expect(screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })).toHaveClass("h-3", "w-3", "text-[9px]")
    expect(screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })).not.toHaveClass("h-4", "w-4")
    expect(screen.getByTitle("app/models/job.rb")).toHaveClass("py-1", "text-2xs")

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])
    expect(screen.getByTitle("app/models/run.rb (+1 -0)")).toHaveClass("py-1")

    rerender(<ReviewableDiff changedFilesPopup files={files} mode="continuous" onCommentLine={vi.fn()} reviewSettings={comfortableSettings} showFileHeaders />)

    expect(screen.getAllByRole("table")[0]).toHaveClass("text-xs")
    expect(getCodeCellText("new")).toHaveClass("py-0.5")
    expect(getCodeCellText("new")).not.toHaveClass("py-0")
    expect(screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })).toHaveClass("h-4", "w-4", "text-2xs")
    expect(screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })).not.toHaveClass("h-3", "w-3")
    expect(screen.getByTitle("app/models/job.rb")).toHaveClass("py-2", "text-xs")
  })

  it("gives desktop split panes equal fixed-width columns when wrapping long one-sided lines", () => {
    render(<ReviewableDiff files={[splitWideLineFile()]} mode="continuous" reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, desktop_view: "split", line_wrapping: "wrap", line_numbers: true }} showFileHeaders />)

    const table = screen.getByRole("table")
    const cols = Array.from(table.querySelectorAll("col"))
    const oldCell = table.querySelector('[data-diff-split-row="true"] [data-diff-split-side="old"]') as HTMLElement
    const newCell = getCodeCellText("new_value_".repeat(40))

    expect(table).toHaveClass("w-full", "table-fixed")
    expect(table).not.toHaveClass("min-w-full")
    expect(cols.map((col) => col.getAttribute("style"))).toEqual([
      "width: 3rem;",
      "width: calc(0.5 * (100% - 7.5rem));",
      "width: 3rem;",
      "width: calc(0.5 * (100% - 7.5rem));",
      "width: 1.5rem;"
    ])
    expect(oldCell).toHaveClass("min-w-0", "whitespace-pre-wrap", "break-words")
    expect(newCell).toHaveClass("min-w-0", "whitespace-pre-wrap", "break-words")
    expect(oldCell.getAttribute("style")).toContain("max-width: 0px")
    expect(oldCell.getAttribute("style")).toContain("width: calc(0.5 * (100% - 7.5rem))")
    expect(newCell.getAttribute("style")).toContain("max-width: 0px")
    expect(newCell.getAttribute("style")).toContain("width: calc(0.5 * (100% - 7.5rem))")
  })

  it("clips desktop split panes instead of letting horizontal-scroll long lines move the center boundary", () => {
    render(<ReviewableDiff files={[splitWideLineFile()]} mode="continuous" reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, desktop_view: "split", line_wrapping: "scroll", line_numbers: false }} showFileHeaders />)

    const table = screen.getByRole("table")
    const cols = Array.from(table.querySelectorAll("col"))
    const oldCell = table.querySelector('[data-diff-split-row="true"] [data-diff-split-side="old"]') as HTMLElement
    const newCell = getCodeCellText("new_value_".repeat(40))

    expect(screen.getByTestId("diff-file-scroll")).toHaveClass("overflow-x-scroll")
    expect(table).toHaveClass("w-full", "table-fixed")
    expect(cols.map((col) => col.getAttribute("style"))).toEqual([
      "width: calc(0.5 * (100% - 1.5rem));",
      "width: calc(0.5 * (100% - 1.5rem));",
      "width: 1.5rem;"
    ])
    expect(oldCell).toHaveClass("min-w-0", "overflow-hidden", "whitespace-pre")
    expect(oldCell).not.toHaveClass("min-w-[40rem]")
    expect(oldCell.getAttribute("style")).toContain("max-width: 0px")
    expect(oldCell.getAttribute("style")).toContain("width: calc(0.5 * (100% - 1.5rem))")
    expect(newCell).toHaveClass("min-w-0", "overflow-hidden", "whitespace-pre")
    expect(newCell).not.toHaveClass("min-w-[40rem]")
    expect(newCell.getAttribute("style")).toContain("max-width: 0px")
    expect(newCell.getAttribute("style")).toContain("width: calc(0.5 * (100% - 1.5rem))")
  })

  it("keeps commented desktop split lines on the split column grid", () => {
    render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        files={files}
        mode="continuous"
        reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, desktop_view: "split", line_wrapping: "wrap", line_numbers: true }}
        showFileHeaders
      />
    )

    expect(screen.getByText("new").closest("tr")).toHaveAttribute("data-diff-split-row", "true")
    expect(screen.getByTestId("diff-review-thread").querySelectorAll("td")).toHaveLength(1)
    expect(screen.getByTestId("diff-review-thread").querySelector("td")).toHaveAttribute("colspan", "5")
  })

  it("keeps desktop split composer rows aligned to the split column grid", () => {
    render(
      <ReviewableDiff
        composingBody="Please keep this visible."
        composingSelection={{ file: files[0], line: { code: "new", kind: "add", newLine: 1, oldLine: null, marker: "+", hunkId: 0 }, side: "new" }}
        files={files}
        mode="continuous"
        reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, desktop_view: "split", line_wrapping: "wrap", line_numbers: true }}
        showFileHeaders
      />
    )

    expect(screen.getByText("new").closest("tr")).toHaveAttribute("data-diff-split-row", "true")
    expect(screen.getByTestId("diff-review-composer").querySelectorAll("td")).toHaveLength(1)
    expect(screen.getByTestId("diff-review-composer").querySelector("td")).toHaveAttribute("colspan", "5")
    expect(within(screen.getByTestId("diff-review-composer")).getByLabelText("Comment")).toHaveValue("Please keep this visible.")
  })

  it("keeps mobile scroll-mode diffs in touch-friendly horizontal scrollers", () => {
    const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({ addEventListener: () => undefined, matches: true, removeEventListener: () => undefined })
    })

    try {
      render(<ReviewableDiff files={[wideLineFile()]} mode="continuous" reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, line_wrapping: "scroll" }} />)

      const scroller = screen.getByTestId("diff-file-scroll")
      expect(scroller).toHaveClass("w-full", "min-w-0", "max-w-full", "overflow-x-scroll", "overscroll-x-contain", "[-webkit-overflow-scrolling:touch]")
      expect(scroller).not.toHaveClass("overflow-x-hidden")
      expect(screen.getByRole("table")).toHaveAttribute("data-review-diff-view", "unified")
      expect(getCodeCellText("x".repeat(240))).toHaveClass("min-w-[40rem]", "whitespace-pre")
    } finally {
      if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia)
      else Reflect.deleteProperty(window, "matchMedia")
    }
  })

  it("renders visible whitespace when enabled", () => {
    render(
      <ReviewableDiff
        files={[{
          additions: 1,
          deletions: 0,
          patch: [
            "diff --git a/f.rb b/f.rb",
            "--- a/f.rb",
            "+++ b/f.rb",
            "@@ -1,1 +1,2 @@",
            " keep value",
            "+new\tvalue  "
          ].join("\n"),
          path: "f.rb",
          status: "modified"
        }]}
        mode="continuous"
        reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, syntax_highlighting: false, visible_whitespace: true }}
      />
    )

    expect(getCodeCellText("keep·value")).toBeInTheDocument()
    expect(getCodeCellText("new→\tvalue··")).toBeInTheDocument()
  })

  it("copies a file's repository-relative path from the diff header", async () => {
    const originalClipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard")
    const writeText = vi.fn(() => Promise.resolve())
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } })

    try {
      render(<ReviewableDiff files={files} mode="continuous" />)

      const copyButton = screen.getByRole("button", { name: "Copy app/models/job.rb to clipboard" })
      fireEvent.click(copyButton)

      expect(writeText).toHaveBeenCalledWith("app/models/job.rb")
      await waitFor(() => expect(copyButton).toHaveAttribute("title", "Copied"))
    } finally {
      if (originalClipboard) Object.defineProperty(navigator, "clipboard", originalClipboard)
      else Reflect.deleteProperty(navigator, "clipboard")
    }
  })

  it("keeps sticky file headers out of transformed virtual rows", () => {
    render(<ReviewableDiff files={files} mode="continuous" showFileHeaders />)

    const firstVirtualRow = screen.getByTestId("agent-diff-viewer").querySelector("[data-index='0']") as HTMLElement
    expect(firstVirtualRow).toHaveStyle({ position: "absolute", top: "0px" })
    expect(firstVirtualRow.style.transform).toBe("")
    expect(within(firstVirtualRow).getByTitle("app/models/job.rb")).toHaveClass("sticky")
  })

  it("extends sticky header containment through the last visible rows", () => {
    render(<ReviewableDiff files={files} mode="continuous" scroll="natural" showFileHeaders />)

    const firstFileSection = screen.getByTitle("app/models/job.rb").closest("[data-diff-file]") as HTMLElement
    expect(firstFileSection).toHaveStyle({ marginBottom: "-37px", paddingBottom: "37px" })
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

  it("treats an empty annotations object as having no annotations, for either shape", () => {
    // Object.values({}).every(...) is vacuously true, so an empty map must
    // never be classified as the flat shape by incidental `.every` semantics.
    expect(isLineAnnotations({})).toBe(false)
    expect(annotationsForFile({}, "app/models/job.rb")).toBeUndefined()
    expect(annotationsForFile(undefined, "app/models/job.rb")).toBeUndefined()
  })

  it("classifies flat and per-file annotation shapes once they have entries", () => {
    expect(isLineAnnotations({ "1": "uncovered" })).toBe(true)
    expect(isLineAnnotations({ "app/models/job.rb": { "1": "uncovered" } })).toBe(false)
  })

  it("does not misapply an empty per-file annotations map to a rendered file", () => {
    render(
      <ReviewableDiff annotations={{}} files={files} mode="single-file" selectedPath="app/models/job.rb" />
    )

    const row = screen.getByText("new").closest("tr")
    expect(row).not.toHaveAttribute("data-coverage")
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

  it("composes a new comment inline in the diff, full width, instead of a separate sidebar form", () => {
    const onChangeComposingBody = vi.fn()
    const onSaveComposing = vi.fn()
    const onCancelComposing = vi.fn()

    render(
      <ReviewableDiff
        composingBody="Please add a regression spec."
        composingSelection={{ file: files[0], line: { code: "new", kind: "add", newLine: 1, oldLine: null, marker: "+", hunkId: -1 }, side: "new" }}
        files={files}
        mode="single-file"
        onCancelComposing={onCancelComposing}
        onChangeComposingBody={onChangeComposingBody}
        onCommentLine={vi.fn()}
        onSaveComposing={onSaveComposing}
        selectedPath="app/models/job.rb"
      />
    )

    const composer = screen.getByTestId("diff-review-composer")
    expect(within(composer).getByLabelText("Comment")).toHaveValue("Please add a regression spec.")

    fireEvent.change(within(composer).getByLabelText("Comment"), { target: { value: "Updated body." } })
    expect(onChangeComposingBody).toHaveBeenCalledWith("Updated body.")

    fireEvent.click(within(composer).getByRole("button", { name: "Create comment" }))
    expect(onSaveComposing).toHaveBeenCalled()

    fireEvent.click(within(composer).getByRole("button", { name: "Cancel" }))
    expect(onCancelComposing).toHaveBeenCalled()
  })

  it("opens the comment composer full screen on mobile, like the workflow transcript panel", () => {
    const onCancelComposing = vi.fn()

    render(
      <ReviewableDiff
        composingBody="Please add a regression spec."
        composingSelection={{ file: files[0], line: { code: "new", kind: "add", newLine: 1, oldLine: null, marker: "+", hunkId: -1 }, side: "new" }}
        files={files}
        mode="single-file"
        onCancelComposing={onCancelComposing}
        onCommentLine={vi.fn()}
        selectedPath="app/models/job.rb"
      />
    )

    const composer = screen.getByTestId("diff-review-composer")
    const overlay = within(composer).getByLabelText("Comment").closest("div.max-md\\:fixed")
    expect(overlay).toHaveClass("max-md:inset-0", "max-md:z-50", "max-md:h-[100dvh]")

    fireEvent.click(within(composer).getByRole("button", { name: "Close comment form" }))
    expect(onCancelComposing).toHaveBeenCalled()
  })

  it("offers to delete a draft diff review thread inline, but not a submitted one", () => {
    const onDeleteThread = vi.fn()

    const { rerender } = render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        files={files}
        mode="single-file"
        onDeleteThread={onDeleteThread}
        selectedPath="app/models/job.rb"
      />
    )

    fireEvent.click(screen.getByRole("button", { name: "Delete" }))
    expect(onDeleteThread).toHaveBeenCalledWith({ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" })

    rerender(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "submitted" }]
          }
        }}
        files={files}
        mode="single-file"
        onDeleteThread={onDeleteThread}
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.queryByRole("button", { name: "Delete" })).not.toBeInTheDocument()
  })

  it("keeps the inline thread's Edit/Delete actions packed next to the author instead of pushed to the far edge of the wide code column", () => {
    render(
      <ReviewableDiff
        comments={{
          "app/models/job.rb": {
            "right::1": [{ id: 1, author: "Ada", body: "Please cover this branch.", state: "draft" }]
          }
        }}
        files={files}
        mode="single-file"
        onDeleteThread={vi.fn()}
        onStartEditThread={vi.fn()}
        selectedPath="app/models/job.rb"
      />
    )

    const deleteButton = screen.getByRole("button", { name: "Delete" })
    const actionRow = deleteButton.closest("div.mb-1")
    expect(actionRow).not.toHaveClass("justify-between")
  })

  it("does not show an inline composer on lines that don't match the active composing selection", () => {
    render(
      <ReviewableDiff
        composingBody="Please add a regression spec."
        composingSelection={{ file: files[0], line: { code: "unrelated", kind: "add", newLine: 999, oldLine: null, marker: "+", hunkId: -1 }, side: "new" }}
        files={files}
        mode="single-file"
        onCommentLine={vi.fn()}
        selectedPath="app/models/job.rb"
      />
    )

    expect(screen.queryByTestId("diff-review-composer")).not.toBeInTheDocument()
  })

  it("bounds the diff height by default but grows naturally when scroll is set to natural", () => {
    const { rerender } = render(<ReviewableDiff files={files} mode="continuous" />)
    expect(screen.getByTestId("agent-diff-viewer").querySelector(".max-h-\\[32rem\\]")).toBeInTheDocument()

    rerender(<ReviewableDiff files={files} mode="continuous" scroll="natural" />)
    expect(screen.getByTestId("agent-diff-viewer").querySelector(".max-h-\\[32rem\\]")).not.toBeInTheDocument()
  })

  it("keeps natural-scroll diffs horizontally scrollable within themselves instead of overflowing the page", () => {
    render(<ReviewableDiff files={files} mode="continuous" scroll="natural" />)
    const viewer = screen.getByTestId("agent-diff-viewer")
    expect(viewer).toHaveClass("min-w-0", "max-w-full", "[contain:inline-size]")
    expect(viewer.querySelector("[data-total-file-count]")).toHaveClass("min-w-0", "max-w-full")
    expect(viewer.querySelector(".overflow-x-scroll")).toHaveClass("w-full", "min-w-0", "max-w-full", "[container-type:inline-size]")
  })

  it("keeps wide-line comment composers anchored to the visible horizontal scroll area", () => {
    const wideFile = wideLineFile()

    render(
      <ReviewableDiff
        composingBody="Please keep this visible."
        composingSelection={{ file: wideFile, line: { code: "x".repeat(240), kind: "add", newLine: 2, oldLine: null, marker: "+", hunkId: -1 }, side: "new" }}
        files={[wideFile]}
        mode="continuous"
        onCommentLine={vi.fn()}
        scroll="natural"
        showFileHeaders
      />
    )

    const composerCells = screen.getByTestId("diff-review-composer").querySelectorAll("td")
    const composerCell = composerCells[composerCells.length - 1] as HTMLElement
    const composerPanel = Array.from(composerCell.children).find((child) => child.tagName === "DIV") as HTMLElement
    expect(composerCell).toHaveClass("max-w-[calc(100vw-3rem)]")
    expect(composerCell).not.toHaveClass("sticky")
    expect(composerPanel).toHaveClass("sticky", "left-0", "w-[min(44rem,100cqw,calc(100vw-3rem))]")
    expect(composerPanel).not.toHaveClass("max-md:static")
    expect(within(composerCell).getByLabelText("Comment")).toHaveValue("Please keep this visible.")
  })

  it("keeps existing review threads viewport-bound when code lines are horizontally scrollable", () => {
    const wideFile = wideLineFile()

    render(
      <ReviewableDiff
        comments={{
          "app/models/wide.rb": {
            "right::2": [{ id: 1, author: "Ada", body: "This note should not inherit the long line width.", state: "draft" }]
          }
        }}
        files={[wideFile]}
        mode="continuous"
        scroll="natural"
        showFileHeaders
      />
    )

    const threadCells = screen.getByTestId("diff-review-thread").querySelectorAll("td")
    const threadCell = threadCells[threadCells.length - 1] as HTMLElement
    const threadPanel = threadCell.querySelector("div")
    expect(threadCell).toHaveClass("max-w-[calc(100vw-3rem)]")
    expect(threadCell).not.toHaveClass("sticky")
    expect(threadPanel).toHaveClass("sticky", "left-0", "w-[min(44rem,100cqw,calc(100vw-3rem))]", "max-md:static")
    expect(screen.getByText("This note should not inherit the long line width.")).toBeInTheDocument()
  })

  it("renders natural-scroll file sections in document flow instead of a virtualized height spacer", () => {
    render(<ReviewableDiff files={manyFiles(20)} mode="continuous" scroll="natural" showFileHeaders />)

    const viewer = screen.getByTestId("agent-diff-viewer")
    const scrollContainer = viewer.querySelector("[data-total-file-count]") as HTMLElement

    expect(scrollContainer).toHaveAttribute("data-rendered-file-count", "20")
    expect(screen.getByTitle("file0.rb")).toBeInTheDocument()
    expect(screen.getByTitle("file19.rb")).toBeInTheDocument()
    expect(viewer.querySelector("[data-index]")).not.toBeInTheDocument()
    expect(viewer.querySelector("[style*='position: relative']")).not.toBeInTheDocument()
  })

  it("renders the add-comment affordance in the left gutter, not the right edge", () => {
    render(<ReviewableDiff files={files} mode="single-file" onCommentLine={vi.fn()} selectedPath="app/models/job.rb" />)

    const button = screen.getByRole("button", { name: "Comment on app/models/job.rb:new:1" })
    const gutterCell = button.closest("td")
    const row = button.closest("tr")

    expect(gutterCell).not.toBeNull()
    expect(row?.querySelectorAll("td")[1]).toBe(gutterCell)
  })

  it("omits the old line-number gutter for added files", () => {
    const addedFile = {
      additions: 2,
      deletions: 0,
      patch: [
        "diff --git a/app/models/new_file.rb b/app/models/new_file.rb",
        "new file mode 100644",
        "index 0000000..1111111",
        "--- /dev/null",
        "+++ b/app/models/new_file.rb",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second"
      ].join("\n"),
      path: "app/models/new_file.rb",
      status: "added"
    }

    const { container } = render(<ReviewableDiff files={[addedFile]} mode="single-file" selectedPath="app/models/new_file.rb" />)
    const hunkRow = container.querySelector('tr[data-diff-kind="hunk"]')
    const addedRows = Array.from(container.querySelectorAll('tr[data-diff-kind="add"]'))

    expect(hunkRow?.querySelectorAll("td")).toHaveLength(4)
    expect(addedRows).toHaveLength(2)
    expect(addedRows[0]?.querySelectorAll("td")).toHaveLength(4)
    expect(addedRows[0]?.querySelector("td")?.textContent).toBe("1")
  })

  it("opens a line comment when tapping a code token on mobile", () => {
    const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({ addEventListener: () => undefined, matches: true, removeEventListener: () => undefined })
    })

    try {
      const onCommentLine = vi.fn()
      render(<ReviewableDiff files={files} mode="single-file" onCommentLine={onCommentLine} selectedPath="app/models/job.rb" />)

      fireEvent.click(getCodeToken("new"))

      expect(onCommentLine).toHaveBeenCalledTimes(1)
      expect(onCommentLine).toHaveBeenCalledWith({
        file: files[0],
        line: expect.objectContaining({ code: "new", kind: "add", newLine: 1, oldLine: null }),
        side: "new"
      })
      expect(screen.queryByText(/Highlighting/)).not.toBeInTheDocument()
    } finally {
      if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia)
      else Reflect.deleteProperty(window, "matchMedia")
    }
  })

  it("keeps desktop row clicks from starting a line comment", () => {
    const onCommentLine = vi.fn()
    render(<ReviewableDiff files={files} mode="single-file" onCommentLine={onCommentLine} selectedPath="app/models/job.rb" />)

    fireEvent.click(getCodeCellText("new"))

    expect(onCommentLine).not.toHaveBeenCalled()
  })

  it("opens an on-demand popup listing changed files and reports the selected one", () => {
    const onSelectFile = vi.fn()
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" onSelectFile={onSelectFile} showFileHeaders />)

    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])

    expect(screen.getByText("Changed files")).toBeInTheDocument()
    fireEvent.click(screen.getByTitle("app/models/run.rb (+1 -0)"))

    expect(onSelectFile).toHaveBeenCalledWith("app/models/run.rb")
    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
  })

  it("closes the changed-files popup when clicking outside the file list", () => {
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])
    expect(screen.getByText("Changed files")).toBeInTheDocument()

    fireEvent.pointerDown(document.body)

    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
  })

  it("closes the changed-files popup with Escape", () => {
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])
    expect(screen.getByText("Changed files")).toBeInTheDocument()

    fireEvent.keyDown(window, { key: "Escape" })

    expect(screen.queryByText("Changed files")).not.toBeInTheDocument()
  })

  it("renders nested changed-files as an expanded collapsible folder tree", () => {
    const onSelectFile = vi.fn()
    render(
      <ReviewableDiff
        changedFilesPopup
        fileCommentCounts={{ "app/models/deep.rb": 3 }}
        files={[
          { additions: 1, deletions: 0, patch: files[0].patch, path: "z.rb", status: "modified" },
          { additions: 5, deletions: 4, patch: files[1].patch, path: "app/models/deep.rb", status: "modified" },
          { additions: 2, deletions: 0, patch: files[1].patch, path: "a.rb", status: "modified" }
        ]}
        mode="continuous"
        onSelectFile={onSelectFile}
        reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, density: "compact", file_list_layout: "nested", file_sort: "change_size" }}
        selectedPath="app/models/deep.rb"
        showFileHeaders
      />
    )

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])

    const dialog = screen.getByRole("dialog")
    const appFolder = within(dialog).getByRole("button", { name: "app" })
    const modelsFolder = within(dialog).getByRole("button", { name: "models" })
    expect(appFolder).toHaveAttribute("aria-expanded", "true")
    expect(modelsFolder).toHaveAttribute("aria-expanded", "true")
    expect(appFolder).toHaveClass("py-1")
    expect(appFolder.querySelector("span")).toHaveClass("rotate-90")

    const changedFiles = screen.getAllByTitle(/ \(\+/)
    expect(changedFiles.map((button) => button.textContent)).toEqual(["deep.rb+5-43", "a.rb+2-0", "z.rb+1-0"])
    expect(within(dialog).queryByText("app/models/deep.rb")).not.toBeInTheDocument()

    const popupText = dialog.textContent || ""
    expect(popupText.indexOf("app")).toBeLessThan(popupText.indexOf("models"))
    expect(popupText.indexOf("models")).toBeLessThan(popupText.indexOf("deep.rb"))
    expect(changedFiles.map((button) => button.getAttribute("title"))).toEqual([
      "app/models/deep.rb (+5 -4)",
      "a.rb (+2 -0)",
      "z.rb (+1 -0)"
    ])

    fireEvent.click(appFolder)
    expect(appFolder).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByTitle("app/models/deep.rb (+5 -4)")).not.toBeInTheDocument()
    expect(screen.getByTitle("a.rb (+2 -0)")).toBeInTheDocument()

    fireEvent.click(appFolder)
    const deepFile = screen.getByTitle("app/models/deep.rb (+5 -4)")
    expect(deepFile).toHaveClass("bg-brand/10", "py-1")

    fireEvent.click(deepFile)
    expect(onSelectFile).toHaveBeenCalledWith("app/models/deep.rb")
  })

  it("scrolls each file's table horizontally on its own instead of sharing one scroll region", () => {
    render(<ReviewableDiff files={files} mode="continuous" showFileHeaders />)

    const viewer = screen.getByTestId("agent-diff-viewer")
    expect(viewer.querySelector(".max-h-\\[32rem\\]")).not.toHaveClass("overflow-x-auto")

    const jobTable = screen.getByText("new").closest("table") as HTMLElement
    const runTable = screen.getByText("added").closest("table") as HTMLElement
    const jobScroller = jobTable.parentElement
    const runScroller = runTable.parentElement

    expect(jobScroller).toHaveClass("overflow-x-scroll")
    expect(runScroller).toHaveClass("overflow-x-scroll")
    expect(jobScroller).not.toBe(runScroller)
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

  it("layers Shiki syntax tokens on top of the diff add/remove background classes", async () => {
    const highlightedFiles = [
      {
        additions: 1,
        deletions: 0,
        patch: [
          "diff --git a/app/models/job.rb b/app/models/job.rb",
          "--- a/app/models/job.rb",
          "+++ b/app/models/job.rb",
          "@@ -1,1 +1,2 @@",
          " class Job",
          "+  def call; end"
        ].join("\n"),
        path: "app/models/job.rb",
        status: "modified"
      }
    ]

    render(<ReviewableDiff files={highlightedFiles} mode="single-file" selectedPath="app/models/job.rb" />)

    // "class"/"def" render immediately as plain (untokenized) spans, then
    // get replaced once the async Shiki fetch resolves -- findByText alone
    // resolves on the first (untokenized) match, so wait for the eventual
    // *tokenized* span specifically instead of racing the fetch.
    const contextKeyword = await waitFor(() => {
      const element = screen.getByText("class")
      expect(element.style.color).toMatch(/^var\(--shiki-token-/)
      return element
    })
    expect(contextKeyword.tagName).toBe("SPAN")

    const addedKeyword = await waitFor(() => {
      const element = screen.getByText("def")
      expect(element.style.color).toMatch(/^var\(--shiki-token-/)
      return element
    })
    expect(addedKeyword.closest("tr")).toHaveClass("bg-green-50")
  })

  it("shows the plain unavailable placeholder for a patch-less non-image file", () => {
    const binaryFiles = [
      { additions: 0, deletions: 0, patch: null, path: "vendor/some.bin", status: "modified" }
    ]

    render(<ReviewableDiff files={binaryFiles} mode="single-file" selectedPath="vendor/some.bin" unavailableState="Diff not available" />)

    expect(screen.getByText("Diff not available")).toBeInTheDocument()
  })

  it("delegates to renderImageDiff for a patch-less image file instead of the plain placeholder", () => {
    const imageFiles = [
      { additions: 0, deletions: 0, is_image: true, patch: null, path: "app/assets/images/logo.png", status: "modified" }
    ]

    render(
      <ReviewableDiff
        files={imageFiles}
        mode="single-file"
        renderImageDiff={(file) => <div data-testid="image-diff">{file.path}</div>}
        selectedPath="app/assets/images/logo.png"
        unavailableState="Diff not available"
      />
    )

    expect(screen.getByTestId("image-diff")).toHaveTextContent("app/assets/images/logo.png")
    expect(screen.queryByText("Diff not available")).not.toBeInTheDocument()
  })

  it("falls back to the plain placeholder for an image file when no renderImageDiff is given", () => {
    const imageFiles = [
      { additions: 0, deletions: 0, is_image: true, patch: null, path: "app/assets/images/logo.png", status: "modified" }
    ]

    render(<ReviewableDiff files={imageFiles} mode="single-file" selectedPath="app/assets/images/logo.png" unavailableState="Diff not available" />)

    expect(screen.getByText("Diff not available")).toBeInTheDocument()
  })
})

describe("large-file gating", () => {
  it("hides a file whose parsed row count exceeds the threshold, and loads it independently of other large files", () => {
    render(<ReviewableDiff files={files} largeFileRowThreshold={1} mode="continuous" showFileHeaders />)

    expect(screen.queryByText("new")).not.toBeInTheDocument()
    expect(screen.queryByText("added")).not.toBeInTheDocument()
    const loadButtons = screen.getAllByRole("button", { name: "Load diff for this file" })
    expect(loadButtons).toHaveLength(2)

    fireEvent.click(loadButtons[0])

    expect(screen.getByText("new")).toBeInTheDocument()
    expect(screen.queryByText("added")).not.toBeInTheDocument()
  })

  it("shows the file path and additions/deletions in the placeholder along with an estimated row count", () => {
    render(<ReviewableDiff files={[files[0]]} largeFileRowThreshold={1} mode="continuous" showFileHeaders />)

    const placeholderPath = screen.getByText("app/models/job.rb", { selector: "p" })
    const placeholder = placeholderPath.parentElement as HTMLElement
    expect(within(placeholder).getByText("+1", { exact: false })).toBeInTheDocument()
    expect(within(placeholder).getByText("-1", { exact: false })).toBeInTheDocument()
    expect(within(placeholder).getByText(/rendered lines/)).toBeInTheDocument()
  })

  it("renders normally when a file's row count is at or under the threshold", () => {
    render(<ReviewableDiff files={[files[0]]} largeFileRowThreshold={100} mode="continuous" showFileHeaders />)

    expect(screen.getByText("new")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Load diff for this file" })).not.toBeInTheDocument()
  })

  function fileWithContextRowCount(rowCount: number) {
    // total rows = 3 header rows (diff/---/+++) + 1 hunk row + N context rows
    const contextRows = rowCount - 4
    const patch = [
      "diff --git a/big.rb b/big.rb",
      "--- a/big.rb",
      "+++ b/big.rb",
      `@@ -1,${contextRows} +1,${contextRows} @@`,
      ...Array.from({ length: contextRows }, (_, i) => ` line ${i + 1}`)
    ].join("\n")
    return { additions: 0, deletions: 0, patch, path: "big.rb", status: "modified" }
  }

  it("respects the ~300-row default threshold with no override needed", () => {
    render(<ReviewableDiff files={[fileWithContextRowCount(300)]} mode="continuous" showFileHeaders />)
    expect(screen.queryByRole("button", { name: "Load diff for this file" })).not.toBeInTheDocument()
  })

  it("gates a file just past the default threshold", () => {
    render(<ReviewableDiff files={[fileWithContextRowCount(301)]} mode="continuous" showFileHeaders />)
    expect(screen.getByRole("button", { name: "Load diff for this file" })).toBeInTheDocument()
  })
})

describe("collapsing a file", () => {
  it("hides a file's diff body without hiding its header when collapsed, and can expand it back", () => {
    render(<ReviewableDiff files={[files[0]]} mode="continuous" showFileHeaders />)

    expect(screen.getByText("new")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Collapse file" }))

    expect(screen.getByTitle("app/models/job.rb")).toBeInTheDocument()
    expect(screen.queryByText("new")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Expand file" }))

    expect(screen.getByText("new")).toBeInTheDocument()
  })

  it("collapses each file independently in continuous mode", () => {
    render(<ReviewableDiff files={files} mode="continuous" showFileHeaders />)

    fireEvent.click(screen.getAllByRole("button", { name: "Collapse file" })[0])

    expect(screen.queryByText("new")).not.toBeInTheDocument()
    expect(screen.getByText("added")).toBeInTheDocument()
  })

  it("collapses a not-yet-loaded large file's placeholder too", () => {
    render(<ReviewableDiff files={[files[0]]} largeFileRowThreshold={1} mode="continuous" showFileHeaders />)

    expect(screen.getByRole("button", { name: "Load diff for this file" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Collapse file" }))

    expect(screen.queryByRole("button", { name: "Load diff for this file" })).not.toBeInTheDocument()
    expect(screen.getByTitle("app/models/job.rb")).toBeInTheDocument()
  })

  it("hides the collapse toggle on narrow viewports via CSS so mobile keeps the extra width", () => {
    render(<ReviewableDiff files={[files[0]]} mode="continuous" showFileHeaders />)

    expect(screen.getByRole("button", { name: "Collapse file" }).className).toMatch(/max-md:hidden/)
  })

  it("does not render a collapse toggle when file headers are hidden", () => {
    render(<ReviewableDiff files={[files[0]]} mode="continuous" showFileHeaders={false} />)

    expect(screen.queryByRole("button", { name: "Collapse file" })).not.toBeInTheDocument()
  })

  it("stops pinning a collapsed file's header, since there's nothing left to scroll past", () => {
    render(<ReviewableDiff files={[files[0]]} mode="continuous" showFileHeaders />)

    expect(screen.getByTitle("app/models/job.rb")).toHaveClass("sticky")

    fireEvent.click(screen.getByRole("button", { name: "Collapse file" }))
    expect(screen.getByTitle("app/models/job.rb")).not.toHaveClass("sticky")

    fireEvent.click(screen.getByRole("button", { name: "Expand file" }))
    expect(screen.getByTitle("app/models/job.rb")).toHaveClass("sticky")
  })
})

describe("changed-file count cap", () => {
  it("renders only the first maxVisibleFiles files by default, with a control to load the rest", () => {
    render(<ReviewableDiff files={manyFiles(5)} maxVisibleFiles={2} mode="continuous" showFileHeaders />)

    expect(screen.getByTitle("file0.rb")).toBeInTheDocument()
    expect(screen.getByTitle("file1.rb")).toBeInTheDocument()
    expect(screen.queryByTitle("file2.rb")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load 2 more files (3 remaining)" }))

    expect(screen.getByTitle("file2.rb")).toBeInTheDocument()
    expect(screen.getByTitle("file3.rb")).toBeInTheDocument()
    expect(screen.queryByTitle("file4.rb")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Load 1 more files (1 remaining)" }))

    expect(screen.getByTitle("file4.rb")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Load .* more files/ })).not.toBeInTheDocument()
  })

  it("does not show the load-more control for diffs smaller than the cap", () => {
    render(<ReviewableDiff files={manyFiles(3)} mode="continuous" showFileHeaders />)

    expect(screen.queryByRole("button", { name: /Load .* more files/ })).not.toBeInTheDocument()
  })
})

// These exercise ReviewableDiff's file-level virtualization (see the
// `data-rendered-file-count`/`data-total-file-count` instrumentation
// attributes on the scroll container): only files near the viewport should
// actually mount, and a file's expanded-context/loaded-whole-file state
// must survive scrolling it out of, then back into, the mounted window.
describe("file-level virtualization", () => {
  function scrollContainerFor(viewer: HTMLElement) {
    return viewer.querySelector("[data-total-file-count]") as HTMLElement
  }

  it("mounts only files near the viewport for a large diff, not every file at once", () => {
    render(<ReviewableDiff files={manyFiles(60)} mode="continuous" showFileHeaders />)

    const scrollContainer = scrollContainerFor(screen.getByTestId("agent-diff-viewer"))
    expect(scrollContainer).toHaveAttribute("data-total-file-count", "60")
    const renderedCount = Number(scrollContainer.getAttribute("data-rendered-file-count"))
    expect(renderedCount).toBeGreaterThan(0)
    expect(renderedCount).toBeLessThan(60)

    expect(screen.getByTitle("file0.rb")).toBeInTheDocument()
    expect(screen.queryByTitle("file50.rb")).not.toBeInTheDocument()
  })

  it("keeps a file's loaded-whole-file state cached after it scrolls out of the virtualized window and back", async () => {
    const onLoadFileContext = vi.fn().mockResolvedValue(Array.from({ length: 10 }, (_, i) => `line ${i + 1}`).join("\n"))
    render(<ReviewableDiff files={manyFiles(60)} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    fireEvent.click(screen.getAllByRole("button", { name: "Load whole file" })[0])
    await screen.findByRole("button", { name: "Whole file loaded" })

    const scrollContainer = scrollContainerFor(screen.getByTestId("agent-diff-viewer"))
    fireEvent.scroll(scrollContainer, { target: { scrollTop: 10_000_000 } })
    expect(screen.queryByTitle("file0.rb")).not.toBeInTheDocument()

    fireEvent.scroll(scrollContainer, { target: { scrollTop: 0 } })
    expect(await screen.findByRole("button", { name: "Whole file loaded" })).toBeDisabled()
    // Cached (not refetched) -- the second mount reused the earlier fetch.
    expect(onLoadFileContext).toHaveBeenCalledTimes(1)
  })

  it("scrolls the virtualized list toward a file selected from the Files menu, even outside the initial window", () => {
    function Controlled() {
      const [selectedPath, setSelectedPath] = useState<string | null>(null)
      return (
        <ReviewableDiff
          changedFilesPopup
          files={manyFiles(60)}
          mode="continuous"
          onSelectFile={setSelectedPath}
          selectedPath={selectedPath}
          showFileHeaders
        />
      )
    }
    render(<Controlled />)

    const scrollContainer = scrollContainerFor(screen.getByTestId("agent-diff-viewer"))
    // jsdom has no Element.prototype.scrollTo at all (real browsers do), and
    // @tanstack/react-virtual calls it through optional chaining, so it's
    // safe to leave unset everywhere else -- define a spy directly on this
    // one element instance (not the shared prototype) so nothing leaks into
    // other tests.
    const scrollToSpy = vi.fn()
    Object.defineProperty(scrollContainer, "scrollTo", { configurable: true, value: scrollToSpy })

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])
    fireEvent.click(screen.getByTitle("file50.rb (+1 -0)"))

    expect(scrollToSpy).toHaveBeenCalled()
  })
})

describe("hidden-context expansion", () => {
  function fileWithHunkAt(startLine: number) {
    return {
      additions: 1,
      deletions: 0,
      patch: [
        "diff --git a/f.rb b/f.rb",
        "--- a/f.rb",
        "+++ b/f.rb",
        `@@ -${startLine},1 +${startLine},2 @@`,
        " keep",
        "+added"
      ].join("\n"),
      path: "f.rb",
      status: "modified"
    }
  }

  it("skips the up-arrow at the file's start boundary without needing a fetch", () => {
    const onLoadFileContext = vi.fn()
    render(<ReviewableDiff files={[fileWithHunkAt(1)]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    expect(screen.queryByLabelText("Load 20 more lines above")).not.toBeInTheDocument()
    expect(screen.getByLabelText("Load 20 more lines below")).toBeInTheDocument()
    expect(onLoadFileContext).not.toHaveBeenCalled()
  })

  it("uses the persisted context-line increment for hidden-context controls", async () => {
    const onLoadFileContext = vi.fn().mockResolvedValue(Array.from({ length: 30 }, (_, i) => `line ${i + 1}`).join("\n"))
    render(
      <ReviewableDiff
        files={[fileWithHunkAt(20)]}
        mode="continuous"
        onLoadFileContext={onLoadFileContext}
        reviewSettings={{ ...DEFAULT_REVIEW_DIFF_SETTINGS, context_lines: 5 }}
        showFileHeaders
      />
    )

    fireEvent.click(screen.getByLabelText("Load 5 more lines above"))

    await findCodeCellText("line 15")
    expect(getCodeCellText("line 19")).toBeInTheDocument()
    expect(screen.getByLabelText("Load 5 more lines above")).toBeInTheDocument()
  })

  it("shows the up-arrow when a hunk starts past line 1, loads real context on click, and hides once the gap is exhausted", async () => {
    const onLoadFileContext = vi.fn().mockResolvedValue(Array.from({ length: 10 }, (_, i) => `line ${i + 1}`).join("\n"))
    render(<ReviewableDiff files={[fileWithHunkAt(5)]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    fireEvent.click(screen.getByLabelText("Load 20 more lines above"))

    await findCodeCellText("line 1")
    expect(onLoadFileContext).toHaveBeenCalledTimes(1)
    expect(getCodeCellText("line 4")).toBeInTheDocument()
    expect(screen.queryByLabelText("Load 20 more lines above")).not.toBeInTheDocument()
  })

  it("preserves existing line-comment anchors after expanding context above them", async () => {
    const onLoadFileContext = vi.fn().mockResolvedValue(Array.from({ length: 10 }, (_, i) => `line ${i + 1}`).join("\n"))
    render(
      <ReviewableDiff
        comments={{ "f.rb": { "right::6": [{ id: 1, author: "Ada", body: "still here", state: "draft" }] } }}
        files={[fileWithHunkAt(5)]}
        mode="continuous"
        onLoadFileContext={onLoadFileContext}
        showFileHeaders
      />
    )

    expect(screen.getByTestId("diff-review-thread")).toHaveTextContent("still here")

    fireEvent.click(screen.getByLabelText("Load 20 more lines above"))
    await findCodeCellText("line 1")

    expect(screen.getByTestId("diff-review-thread")).toHaveTextContent("still here")
  })

  it("loads below-hunk context after the current hunk body and before the next hunk", async () => {
    const twoHunkFile = {
      additions: 0,
      deletions: 0,
      patch: [
        "diff --git a/f.rb b/f.rb",
        "--- a/f.rb",
        "+++ b/f.rb",
        "@@ -1,1 +1,1 @@",
        " first",
        "@@ -6,1 +6,1 @@",
        " second"
      ].join("\n"),
      path: "f.rb",
      status: "modified"
    }
    const onLoadFileContext = vi.fn().mockResolvedValue([
      "first",
      "between 2",
      "between 3",
      "between 4",
      "between 5",
      "second"
    ].join("\n"))
    render(<ReviewableDiff files={[twoHunkFile]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    fireEvent.click(screen.getAllByLabelText("Load 20 more lines below")[0])

    await findCodeCellText("between 2")
    const codeCells = Array.from(screen.getAllByRole("cell"))
      .filter((cell) => cell.className.includes("min-w-[40rem]"))
      .map((cell) => cell.textContent)
    expect(codeCells).toEqual([
      "diff --git a/f.rb b/f.rb",
      "--- a/f.rb",
      "+++ b/f.rb",
      "first",
      "between 2",
      "between 3",
      "between 4",
      "between 5",
      "second"
    ])
    expect(screen.queryByText("@@ -1,1 +1,1 @@")).not.toBeInTheDocument()
    expect(screen.queryByText("@@ -6,1 +6,1 @@")).not.toBeInTheDocument()
  })

  it("syntax-highlights context loaded from chunk expansion", async () => {
    const twoHunkFile = {
      additions: 0,
      deletions: 0,
      patch: [
        "diff --git a/f.rb b/f.rb",
        "--- a/f.rb",
        "+++ b/f.rb",
        "@@ -1,1 +1,1 @@",
        " class First; end",
        "@@ -6,1 +6,1 @@",
        " class Second; end"
      ].join("\n"),
      path: "f.rb",
      status: "modified"
    }
    const onLoadFileContext = vi.fn().mockResolvedValue([
      "class First; end",
      "def loaded_context",
      "  true",
      "end",
      "",
      "class Second; end"
    ].join("\n"))
    render(<ReviewableDiff files={[twoHunkFile]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    fireEvent.click(screen.getAllByLabelText("Load 20 more lines below")[0])

    const loadedKeyword = await waitFor(() => {
      const element = screen.getByText("def")
      expect(element.style.color).toMatch(/^var\(--shiki-token-/)
      return element
    })
    expect(loadedKeyword.closest("tr")).toHaveAttribute("data-diff-kind", "context")
  })

  it("degrades to plain text without an unhandled rejection when the highlighter fails to load (e.g. CSP-blocked WASM)", async () => {
    const tokenizeSpy = vi.spyOn(highlighterLib, "tokenizeLines").mockRejectedValue(new Error("wasm-unsafe-eval blocked"))
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})

    render(<ReviewableDiff files={files} mode="continuous" showFileHeaders />)

    await waitFor(() => expect(tokenizeSpy).toHaveBeenCalled())
    await waitFor(() => expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("Diff syntax highlighting failed"), expect.any(Error)))

    expect(getCodeCellText("old")).toBeInTheDocument()
    expect(getCodeCellText("new")).toBeInTheDocument()

    tokenizeSpy.mockRestore()
    warnSpy.mockRestore()
  })

  it("loads the whole file via the header action, revealing all hidden context at once", async () => {
    const onLoadFileContext = vi.fn().mockResolvedValue(Array.from({ length: 10 }, (_, i) => `line ${i + 1}`).join("\n"))
    render(<ReviewableDiff files={[fileWithHunkAt(5)]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    fireEvent.click(screen.getByRole("button", { name: "Load whole file" }))

    await findCodeCellText("line 1")
    expect(getCodeCellText("line 2")).toBeInTheDocument()
    expect(getCodeCellText("line 3")).toBeInTheDocument()
    expect(getCodeCellText("line 4")).toBeInTheDocument()
    expect(await screen.findByRole("button", { name: "Whole file loaded" })).toBeDisabled()
  })

  it("hides context-expansion controls entirely when no loader is provided", () => {
    render(<ReviewableDiff files={[fileWithHunkAt(5)]} mode="continuous" showFileHeaders />)

    expect(screen.queryByLabelText("Load 20 more lines above")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Load 20 more lines below")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Load whole file" })).not.toBeInTheDocument()
  })

  it("hides context-expansion controls for a removed file, since its content no longer exists at the head ref", () => {
    const onLoadFileContext = vi.fn()
    const removedFile = { ...fileWithHunkAt(5), status: "removed" }
    render(<ReviewableDiff files={[removedFile]} mode="continuous" onLoadFileContext={onLoadFileContext} showFileHeaders />)

    expect(screen.queryByLabelText("Load 20 more lines above")).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Load 20 more lines below")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Load whole file" })).not.toBeInTheDocument()
    expect(onLoadFileContext).not.toHaveBeenCalled()
  })
})

describe("word-occurrence highlighting", () => {
  const highlightFiles = [
    {
      additions: 1,
      deletions: 1,
      patch: ["diff --git a/a.rb b/a.rb", "--- a/a.rb", "+++ b/a.rb", "@@ -1,1 +1,1 @@", "-old", "+shared_token"].join("\n"),
      path: "a.rb"
    },
    {
      additions: 1,
      deletions: 1,
      patch: ["diff --git a/b.rb b/b.rb", "--- a/b.rb", "+++ b/b.rb", "@@ -1,1 +1,1 @@", "-old", "+shared_token"].join("\n"),
      path: "b.rb"
    }
  ]

  it("highlights every occurrence of a clicked token across all rendered files, and clears on re-click", () => {
    render(<ReviewableDiff files={highlightFiles} mode="continuous" showFileHeaders />)

    const occurrences = screen.getAllByText("shared_token")
    expect(occurrences).toHaveLength(2)

    fireEvent.click(occurrences[0])
    occurrences.forEach((el) => expect(el).toHaveClass("bg-amber-200"))

    fireEvent.click(occurrences[0])
    occurrences.forEach((el) => expect(el).not.toHaveClass("bg-amber-200"))
  })

  it("never turns punctuation into a clickable highlight target", () => {
    const punctFiles = [{
      additions: 1,
      deletions: 1,
      patch: ["diff --git a/a.rb b/a.rb", "--- a/a.rb", "+++ b/a.rb", "@@ -1,1 +1,1 @@", "-old", "+foo();"].join("\n"),
      path: "a.rb"
    }]
    render(<ReviewableDiff files={punctFiles} mode="continuous" showFileHeaders />)

    expect(screen.getByText("(")).not.toHaveClass("cursor-pointer")
    expect(screen.getByText(")")).not.toHaveClass("cursor-pointer")
  })

  it("does not render a highlight note and clears when clicking non-identifier diff content", () => {
    const punctFiles = [{
      additions: 1,
      deletions: 1,
      patch: ["diff --git a/a.rb b/a.rb", "--- a/a.rb", "+++ b/a.rb", "@@ -1,1 +1,1 @@", "-old", "+shared_token();"].join("\n"),
      path: "a.rb"
    }]
    render(<ReviewableDiff files={punctFiles} mode="continuous" showFileHeaders />)

    fireEvent.click(screen.getByText("shared_token"))
    expect(screen.queryByText(/Highlighting/)).not.toBeInTheDocument()
    expect(screen.getByText("shared_token")).toHaveClass("bg-amber-200")

    fireEvent.click(screen.getByText("("))

    expect(screen.getByText("shared_token")).not.toHaveClass("bg-amber-200")
  })
})

describe("changed files menu placement", () => {
  const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")
  const originalInnerHeight = Object.getOwnPropertyDescriptor(window, "innerHeight")

  afterEach(() => {
    if (originalMatchMedia) Object.defineProperty(window, "matchMedia", originalMatchMedia)
    else Reflect.deleteProperty(window, "matchMedia")
    if (originalInnerHeight) Object.defineProperty(window, "innerHeight", originalInnerHeight)
  })

  function stubMobile(matches: boolean) {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({ addEventListener: () => undefined, matches, removeEventListener: () => undefined })
    })
  }

  function rect(overrides: Partial<DOMRect>): DOMRect {
    return { bottom: 0, height: 0, left: 0, right: 0, top: 0, toJSON: () => ({}), width: 0, x: 0, y: 0, ...overrides }
  }

  it("opens below the Files button when there is enough space, sized to cover the diff area", () => {
    stubMobile(false)
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)

    Object.defineProperty(window, "innerHeight", { configurable: true, value: 800 })
    vi.spyOn(screen.getByTestId("agent-diff-viewer"), "getBoundingClientRect").mockReturnValue(rect({ left: 40, width: 500 }))
    const filesButton = screen.getAllByRole("button", { name: "Browse changed files" })[0]
    vi.spyOn(filesButton, "getBoundingClientRect").mockReturnValue(rect({ bottom: 120, top: 100 }))

    fireEvent.click(filesButton)

    const dialog = screen.getByRole("dialog")
    expect(dialog).toHaveStyle({ left: "40px", top: "128px", width: "500px" })
  })

  it("opens above the Files button when there isn't enough space below", () => {
    stubMobile(false)
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)

    Object.defineProperty(window, "innerHeight", { configurable: true, value: 800 })
    vi.spyOn(screen.getByTestId("agent-diff-viewer"), "getBoundingClientRect").mockReturnValue(rect({ left: 40, width: 500 }))
    const filesButton = screen.getAllByRole("button", { name: "Browse changed files" })[0]
    vi.spyOn(filesButton, "getBoundingClientRect").mockReturnValue(rect({ bottom: 720, top: 700 }))

    fireEvent.click(filesButton)

    const dialog = screen.getByRole("dialog")
    expect(dialog.style.top).toBe("")
    expect(dialog).toHaveStyle({ bottom: "108px" })
  })

  it("renders a fullscreen modal instead of a floating menu on mobile", () => {
    stubMobile(true)
    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)

    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])

    const dialog = screen.getByRole("dialog")
    expect(dialog).toHaveClass("fixed", "inset-0", "z-[60]", "h-[100dvh]", "w-[100dvw]")
    expect(screen.getByTestId("agent-diff-viewer")).not.toContainElement(dialog)
    expect(dialog.parentElement).toBe(document.body)
    expect(screen.getByRole("button", { name: "Close changed files" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Close changed files" }))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })
})

describe("performance markers", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("marks parsing, viewport rendering, and comment thread rendering while the diff renders", () => {
    const startMarkerSpy = vi.spyOn(performanceMarkers, "startMarker")
    const recordCountSpy = vi.spyOn(performanceMarkers, "recordCount")

    render(
      <ReviewableDiff
        comments={{ "app/models/job.rb": { anchor: [ { author: "reviewer", body: "look here", id: 1, state: "draft" } ] } }}
        files={files}
        mode="continuous"
      />
    )

    expect(startMarkerSpy).toHaveBeenCalledWith("diff_review.parse_diff", expect.objectContaining({ maxPerSession: 300 }))
    expect(recordCountSpy).toHaveBeenCalledWith("diff_review.viewport_render", expect.objectContaining({
      metadata: expect.objectContaining({ total_files: files.length })
    }))
    expect(recordCountSpy).toHaveBeenCalledWith("diff_review.comment_threads_render", expect.objectContaining({
      metadata: expect.objectContaining({ thread_count: 1 })
    }))
  })

  it("times the Files menu from open to render as one span", () => {
    const startMarkerSpy = vi.spyOn(performanceMarkers, "startMarker")
    const endMarkerSpy = vi.spyOn(performanceMarkers, "endMarker")

    render(<ReviewableDiff changedFilesPopup files={files} mode="continuous" showFileHeaders />)
    fireEvent.click(screen.getAllByRole("button", { name: "Browse changed files" })[0])

    expect(startMarkerSpy).toHaveBeenCalledWith("diff_review.files_menu_open", expect.objectContaining({ maxPerSession: 200 }))
    expect(endMarkerSpy).toHaveBeenCalledWith(
      expect.objectContaining({ name: "diff_review.files_menu_open" }),
      expect.objectContaining({ metadata: { total_files: files.length } })
    )
  })

  it("marks navigating to a selected file as an anchor_scroll span", () => {
    const measureSyncSpy = vi.spyOn(performanceMarkers, "measureSync")

    render(<ReviewableDiff files={files} mode="continuous" selectedPath="app/models/run.rb" />)

    expect(measureSyncSpy).toHaveBeenCalledWith(
      "diff_review.anchor_scroll",
      expect.any(Function),
      expect.objectContaining({ metadata: expect.objectContaining({ selected_path: "app/models/run.rb" }) })
    )
  })
})

describe("DiffHunkSnippet", () => {
  it("renders the surrounding diff context around a comment, above and below the commented line", () => {
    const hunk = ["@@ -1,2 +1,2 @@", "-old", "+new"].join("\n")
    render(<DiffHunkSnippet highlightLine="+new" hunk={hunk} />)

    expect(screen.getByText("@@ -1,2 +1,2 @@")).toBeInTheDocument()
    expect(screen.getByText("-old")).toBeInTheDocument()
    const highlighted = screen.getByText("+new")
    expect(highlighted).toHaveClass("ring-brand")
    expect(screen.getByText("-old")).not.toHaveClass("ring-brand")
  })
})
