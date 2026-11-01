import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ImageDiffThumbnails, renderedFileKind } from "./ImageDiffThumbnails"

describe("ImageDiffThumbnails", () => {
  it("renders before and after inline and expands either side in place", () => {
    render(
      <ImageDiffThumbnails
        baseRef="base-sha"
        file={{ additions: 0, deletions: 0, patch: null, path: "app/assets/images/logo.png", status: "modified" }}
        headRef="head-sha"
        jobId={42}
      />
    )

    expect(screen.getByRole("img", { name: "Before: app/assets/images/logo.png" })).toHaveAttribute(
      "src",
      "/api/v1/app/jobs/42/source_image?ref=base-sha&path=app%2Fassets%2Fimages%2Flogo.png"
    )
    expect(screen.getByRole("img", { name: "After: app/assets/images/logo.png" })).toHaveAttribute(
      "src",
      "/api/v1/app/jobs/42/source_image?ref=head-sha&path=app%2Fassets%2Fimages%2Flogo.png"
    )

    fireEvent.click(screen.getAllByRole("button", { name: "Expand" })[1])
    expect(screen.queryByRole("img", { name: "Before: app/assets/images/logo.png" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Restore comparison" }))
    expect(screen.getByRole("img", { name: "Before: app/assets/images/logo.png" })).toBeInTheDocument()
  })

  it("shows a no-previous-version placeholder instead of a before thumbnail for an added file", () => {
    render(
      <ImageDiffThumbnails
        baseRef="base-sha"
        file={{ additions: 3, deletions: 0, patch: null, path: "app/assets/images/new.png", status: "added" }}
        headRef="head-sha"
        jobId={42}
      />
    )

    expect(screen.queryByRole("img", { name: /Before:/ })).not.toBeInTheDocument()
    expect(screen.getByRole("img", { name: "After: app/assets/images/new.png" })).toBeInTheDocument()
  })

  it("shows a no-new-version placeholder instead of an after thumbnail for a removed file", () => {
    render(
      <ImageDiffThumbnails
        baseRef="base-sha"
        file={{ additions: 0, deletions: 3, patch: null, path: "app/assets/images/gone.png", status: "removed" }}
        headRef="head-sha"
        jobId={42}
      />
    )

    expect(screen.queryByRole("img", { name: /After:/ })).not.toBeInTheDocument()
    expect(screen.getByRole("img", { name: "Before: app/assets/images/gone.png" })).toBeInTheDocument()
  })

  it("shows a placeholder instead of a thumbnail when a ref is unavailable", () => {
    render(
      <ImageDiffThumbnails
        baseRef={null}
        file={{ additions: 0, deletions: 0, patch: null, path: "app/assets/images/logo.png", status: "modified" }}
        headRef="head-sha"
        jobId={42}
      />
    )

    expect(screen.queryByRole("button", { name: "Open Before" })).not.toBeInTheDocument()
    expect(screen.getByText("Previous version unavailable")).toBeInTheDocument()
  })

  it("shows a render failure state when an image resource fails", () => {
    render(<ImageDiffThumbnails baseRef="base-sha" file={{ patch: null, path: "logo.svg", status: "removed" }} headRef="head-sha" jobId={42} />)
    fireEvent.error(screen.getByRole("img", { name: "Before: logo.svg" }))
    expect(screen.getByText("Preview could not be rendered")).toBeInTheDocument()
  })

  it("classifies textual renderable extensions without treating ordinary text as an image", () => {
    expect(renderedFileKind({ path: "README.markdown", patch: "diff" })).toBe("markdown")
    expect(renderedFileKind({ path: "docs/notes.mdown", patch: "diff" })).toBe("markdown")
    expect(renderedFileKind({ path: "logo.svg", patch: "diff" })).toBe("svg")
    expect(renderedFileKind({ path: "notes.txt", patch: "diff" })).toBeNull()
  })

  it("loads and sanitizes both Markdown sides through the shared renderer", async () => {
    render(
      <ImageDiffThumbnails
        baseRef="base-sha"
        file={{ patch: "diff", path: "README.md", status: "modified" }}
        headRef="head-sha"
        jobId={42}
        kind="markdown"
        loadContents={async () => ({ before: "# Before", after: "# After\n<script>alert(1)</script>" })}
      />
    )

    await waitFor(() => expect(screen.getByRole("heading", { name: "Before" })).toBeInTheDocument())
    expect(screen.getByRole("heading", { name: "After" })).toBeInTheDocument()
    expect(document.querySelector("script")).toBeNull()
  })
})
