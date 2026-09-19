import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { canonicalReviewVersions, DiffReviewVersionSelector } from "./DiffReviewVersionSelector"
import type { DiffReviewVersion } from "../../api/jobs"

function allChangesVersion(overrides: Partial<DiffReviewVersion>): DiffReviewVersion {
  return {
    id: 1,
    job_id: 42,
    version_index: 1,
    base_sha: "base-sha",
    head_sha: "head-sha",
    base_ref: "main",
    head_ref: "syrus/issue-42",
    workflow_id: null,
    workflow: null,
    run_id: null,
    trigger_kind: null,
    label: "All changes",
    reason: "source_diff",
    truncated: false,
    files_count: 1,
    comments_count: 0,
    metadata: { range_kind: "all_changes" },
    created_at: "2026-05-01T12:00:00Z",
    ...overrides
  }
}

describe("canonicalReviewVersions", () => {
  it("collapses two source_diff versions (a legacy duplicate) into the most recent single All changes entry", () => {
    const older = allChangesVersion({ id: 1, version_index: 1, head_sha: "claude-head" })
    const newer = allChangesVersion({ id: 2, version_index: 2, head_sha: "codex-head" })

    const canonical = canonicalReviewVersions([ older, newer ])

    expect(canonical).toEqual([ newer ])
  })

  it("leaves a single All changes version untouched" , () => {
    const version = allChangesVersion({ id: 1 })

    expect(canonicalReviewVersions([ version ])).toEqual([ version ])
  })

  it("drops an empty legacy All changes version when real review versions exist", () => {
    const emptyAllChanges = allChangesVersion({ id: 1, files_count: 0, base_sha: "main", head_sha: "main" })
    const runVersion: DiffReviewVersion = {
      ...allChangesVersion({ id: 2 }),
      reason: "initial",
      metadata: {},
      run_id: 10,
      base_sha: "a",
      head_sha: "b",
      files_count: 3
    }

    expect(canonicalReviewVersions([ emptyAllChanges, runVersion ])).toEqual([ runVersion ])
  })

  it("does not affect non All-changes versions with distinct run ranges", () => {
    const rangeA: DiffReviewVersion = {
      ...allChangesVersion({ id: 1 }),
      reason: "initial",
      metadata: {},
      run_id: 10,
      base_sha: "a",
      head_sha: "b"
    }
    const rangeB: DiffReviewVersion = {
      ...allChangesVersion({ id: 2 }),
      reason: "initial",
      metadata: {},
      run_id: 11,
      base_sha: "b",
      head_sha: "c"
    }

    expect(canonicalReviewVersions([ rangeA, rangeB ])).toEqual([ rangeA, rangeB ])
  })
})

describe("DiffReviewVersionSelector", () => {
  it("renders only one All changes option in the dropdown when the payload carries a legacy duplicate", () => {
    const versions = [
      allChangesVersion({ id: 1, version_index: 1, head_sha: "claude-head" }),
      allChangesVersion({ id: 2, version_index: 2, head_sha: "codex-head" })
    ]

    render(
      <DiffReviewVersionSelector
        latestVersionId={2}
        onChange={() => {}}
        selectedVersionId={2}
        versions={versions}
      />
    )

    expect(screen.getAllByText("All changes")).toHaveLength(1)
  })
})
