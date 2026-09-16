import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ImageDiffThumbnails } from "./ImageDiffThumbnails"

describe("ImageDiffThumbnails", () => {
  it("renders before and after thumbnails that expand into the standard preview modal", () => {
    render(
      <ImageDiffThumbnails
        baseRef="base-sha"
        file={{ additions: 0, deletions: 0, patch: null, path: "app/assets/images/logo.png", status: "modified" }}
        headRef="head-sha"
        jobId={42}
      />
    )

    const beforeButton = screen.getByRole("button", { name: "Open Before" })
    const afterButton = screen.getByRole("button", { name: "Open After" })
    expect(beforeButton.querySelector("img")).toHaveAttribute("src", "/api/v1/app/jobs/42/source_image?ref=base-sha&path=app%2Fassets%2Fimages%2Flogo.png")
    expect(afterButton.querySelector("img")).toHaveAttribute("src", "/api/v1/app/jobs/42/source_image?ref=head-sha&path=app%2Fassets%2Fimages%2Flogo.png")

    fireEvent.click(afterButton)
    expect(screen.getByRole("dialog", { name: "After" })).toBeInTheDocument()
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

    expect(screen.queryByRole("button", { name: "Open Before" })).not.toBeInTheDocument()
    expect(screen.getByText("No previous version (file added)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open After" })).toBeInTheDocument()
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

    expect(screen.queryByRole("button", { name: "Open After" })).not.toBeInTheDocument()
    expect(screen.getByText("No new version (file removed)")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open Before" })).toBeInTheDocument()
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
})
