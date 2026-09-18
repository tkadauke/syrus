import { useState } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { canonicalReviewVersions, DiffReviewVersionSelector } from "./DiffReviewVersionSelector"
import type { DiffReviewRangeSelection } from "./DiffReviewVersionSelector"
import type { DiffReviewVersion } from "../../api/jobs"

function rangeVersion(overrides: Partial<DiffReviewVersion>): DiffReviewVersion {
  return {
    id: 1,
    job_id: 42,
    version_index: 1,
    base_sha: "base-sha",
    head_sha: "head-sha",
    base_ref: "main",
    head_ref: "syrus/issue-42",
    workflow_id: 1,
    workflow: null,
    run_id: 1,
    trigger_kind: "initial",
    label: null,
    reason: "initial",
    truncated: false,
    files_count: 1,
    comments_count: 0,
    metadata: {},
    created_at: "2026-05-01T12:00:00Z",
    ...overrides
  }
}

function highlightedChips(name: RegExp) {
  return screen.getAllByRole("button", { name }).filter((button) => button.className.includes("bg-brand"))
}

function ControlledSelector({ latestVersionId, versions }: { latestVersionId: number | null; versions: DiffReviewVersion[] }) {
  const [selectedVersionId, setSelectedVersionId] = useState<number | null>(latestVersionId)
  const [selectedRange, setSelectedRange] = useState<{ baseSha: string; headSha: string } | null>(null)

  function handleRangeChange(range: DiffReviewRangeSelection) {
    setSelectedVersionId(range.versionId)
    setSelectedRange({ baseSha: range.baseSha, headSha: range.headSha })
  }

  return (
    <DiffReviewVersionSelector
      latestVersionId={latestVersionId}
      onChange={(id) => {
        setSelectedVersionId(id)
        setSelectedRange(null)
      }}
      onRangeChange={handleRangeChange}
      selectedRange={selectedRange}
      selectedVersionId={selectedVersionId}
      versions={versions}
    />
  )
}

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

  it("highlights exactly one FROM chip and one TO chip when a single version is selected, even if an earlier version shares its base_sha", () => {
    const initial = rangeVersion({ id: 1, version_index: 1, workflow_id: 10, run_id: 100, base_sha: "shared-base", head_sha: "claude-head" })
    const retry = rangeVersion({ id: 2, version_index: 2, workflow_id: 11, run_id: 101, base_sha: "shared-base", head_sha: "retry-head" })

    render(
      <DiffReviewVersionSelector
        latestVersionId={2}
        onChange={() => {}}
        selectedRange={null}
        selectedVersionId={2}
        versions={[ initial, retry ]}
      />
    )

    fireEvent.click(screen.getByRole("button", { name: /Version/ }))

    expect(highlightedChips(/^From/)).toHaveLength(1)
    expect(highlightedChips(/^To/)).toHaveLength(1)
  })

  it("highlights exactly one FROM chip and one TO chip after building an explicit custom FROM/TO range via chip clicks", () => {
    const first = rangeVersion({ id: 1, version_index: 1, workflow_id: 10, run_id: 100, base_sha: "a", head_sha: "b" })
    const second = rangeVersion({ id: 2, version_index: 2, workflow_id: 11, run_id: 101, base_sha: "b", head_sha: "c" })
    const third = rangeVersion({ id: 3, version_index: 3, workflow_id: 12, run_id: 102, base_sha: "c", head_sha: "d" })

    render(<ControlledSelector latestVersionId={3} versions={[ first, second, third ]} />)

    fireEvent.click(screen.getByRole("button", { name: /Version/ }))
    fireEvent.click(screen.getByRole("button", { name: /^From.*v1/ }))

    fireEvent.click(screen.getByRole("button", { name: /Version/ }))

    expect(highlightedChips(/^From/)).toHaveLength(1)
    expect(highlightedChips(/^To/)).toHaveLength(1)
  })
})
