import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { TypedArtifact } from "../../api/artifacts"
import { TypedArtifactPanel } from "./TypedArtifactPanel"

describe("TypedArtifactPanel", () => {
  it("keeps long artifact chrome and bodies constrained to a horizontal scroller", () => {
    const artifact: TypedArtifact = {
      type: "rails_migration_diff_with_a_long_renderer_type_label",
      title: "20261116010100_create_diff_review_versions_with_a_long_migration_filename.rb",
      created_at: "2026-08-06T10:00:00Z",
      renderer_type: "migration_diff",
      payload: {
        migration_name: "CreateDiffReviewVersions",
        before: { table_name: "diff_review_versions", columns: [{ name: "old_diff_review_versions_column", type: "string" }] },
        after: { table_name: "diff_review_versions", columns: [{ name: "new_diff_review_versions_column", type: "string" }] },
        changes: [{ type: "added", column: { name: "new_diff_review_versions_column", type: "string" } }]
      }
    }

    const { container } = render(<TypedArtifactPanel artifacts={[artifact]} />)

    const card = screen.getByText(artifact.title).closest(".rounded")
    expect(card).toHaveClass("min-w-0", "overflow-hidden")
    expect(screen.getByText(artifact.title).parentElement).toHaveClass("flex-wrap")
    expect(screen.getByText(artifact.type)).toHaveClass("break-all")
    expect(container.querySelector(".overflow-x-auto")).toBeInTheDocument()
  })
})
