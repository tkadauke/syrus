import { useState } from "react"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { canonicalReviewVersions, DiffReviewVersionSelector, duplicateAllChangesIds, duplicateRunIds } from "./DiffReviewVersionSelector"
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
  it("keeps two distinct non-empty All changes versions instead of collapsing them", () => {
    // Each "All changes" recomputation now persists its own immutable row
    // (JobSourceDiffPayload#resolve_diff_review_version no longer mutates a
    // shared row in place), so two real rows are genuine history, not a
    // legacy duplicate to collapse.
    const older = allChangesVersion({ id: 1, version_index: 1, head_sha: "claude-head" })
    const newer = allChangesVersion({ id: 2, version_index: 2, head_sha: "codex-head" })

    const canonical = canonicalReviewVersions([ older, newer ])

    expect(canonical).toEqual([ older, newer ])
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

  it("keeps a resumed Run's second, different commit range as its own distinct row instead of collapsing it", () => {
    const first = rangeVersion({ id: 6, version_index: 6, workflow_id: 20, run_id: 149674, base_sha: "base-a", head_sha: "aaaaaaa1111111" })
    const second = rangeVersion({ id: 7, version_index: 7, workflow_id: 20, run_id: 149674, base_sha: "base-b", head_sha: "bbbbbbb2222222" })

    expect(canonicalReviewVersions([ first, second ])).toEqual([ first, second ])
  })
})

describe("duplicateRunIds", () => {
  it("flags a run_id only when it appears on more than one version", () => {
    const first = rangeVersion({ id: 6, run_id: 149674, head_sha: "aaaaaaa1111111" })
    const second = rangeVersion({ id: 7, run_id: 149674, head_sha: "bbbbbbb2222222" })
    const other = rangeVersion({ id: 8, run_id: 200, head_sha: "ccccccc3333333" })

    expect(duplicateRunIds([ first, second, other ])).toEqual(new Set([ 149674 ]))
  })

  it("returns an empty set when every version has its own run_id", () => {
    const first = rangeVersion({ id: 1, run_id: 100 })
    const second = rangeVersion({ id: 2, run_id: 101 })

    expect(duplicateRunIds([ first, second ])).toEqual(new Set())
  })
})

describe("duplicateAllChangesIds", () => {
  it("flags every All changes version's id when more than one is present", () => {
    const older = allChangesVersion({ id: 1, version_index: 1, head_sha: "aaaaaaa1111111" })
    const newer = allChangesVersion({ id: 2, version_index: 2, head_sha: "bbbbbbb2222222" })
    const runVersion = rangeVersion({ id: 3, run_id: 200 })

    expect(duplicateAllChangesIds([ older, newer, runVersion ])).toEqual(new Set([ 1, 2 ]))
  })

  it("returns an empty set when only one All changes version is present", () => {
    const version = allChangesVersion({ id: 1 })

    expect(duplicateAllChangesIds([ version ])).toEqual(new Set())
  })
})

describe("DiffReviewVersionSelector", () => {
  it("drops an empty legacy All changes option from the dropdown once a real one exists", () => {
    const versions = [
      allChangesVersion({ id: 1, version_index: 1, base_sha: "main", head_sha: "main", files_count: 0 }),
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

  it("gives two distinct All changes versions disambiguated dropdown row labels instead of showing the same text twice", () => {
    // Regression: each "All changes" recomputation now persists its own
    // immutable row (see JobSourceDiffPayload#resolve_diff_review_version),
    // so a Job with two historical "All changes" reads must render them as
    // distinguishable rows, not two identical "All changes" entries -- the
    // exact duplicate-looking-rows symptom this Epic was filed to fix.
    const older = allChangesVersion({ id: 1, version_index: 1, head_sha: "aaaaaaa1111111" })
    const newer = allChangesVersion({ id: 2, version_index: 2, head_sha: "bbbbbbb2222222" })

    render(
      <DiffReviewVersionSelector
        latestVersionId={2}
        onChange={() => {}}
        selectedVersionId={2}
        versions={[ older, newer ]}
      />
    )

    expect(screen.getByText("All changes (bbbbbbb)")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Version/ }))
    const listbox = screen.getByRole("listbox", { name: "Version" })

    expect(screen.queryAllByText("All changes")).toHaveLength(0)
    expect(within(listbox).getByText("All changes (aaaaaaa)")).toBeInTheDocument()
    expect(within(listbox).getByText("All changes (bbbbbbb)")).toBeInTheDocument()
  })

  it("gives a resumed Run's two versions distinguishable dropdown row labels instead of showing the same Run identifier twice", () => {
    const first = rangeVersion({ id: 6, version_index: 6, workflow_id: 20, run_id: 149674, base_sha: "main-sha", head_sha: "aaaaaaa1111111" })
    const second = rangeVersion({ id: 7, version_index: 7, workflow_id: 20, run_id: 149674, base_sha: "aaaaaaa1111111", head_sha: "bbbbbbb2222222" })

    render(
      <DiffReviewVersionSelector
        latestVersionId={7}
        onChange={() => {}}
        selectedVersionId={7}
        versions={[ first, second ]}
      />
    )

    // The selected/collapsed label on the closed button must not read the
    // bare "RUN-149674" for the currently selected (later) version -- that
    // is indistinguishable from what the earlier version would also show.
    expect(screen.getByText("RUN-149674 (bbbbbbb)")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Version/ }))

    const rows = screen.getAllByText(/^v[67] RUN-149674/)
    expect(rows.map((row) => row.textContent)).toEqual([ "v6 RUN-149674 (aaaaaaa)", "v7 RUN-149674 (bbbbbbb)" ])
  })

  it("keeps the plain RUN-<id> label when a run_id is not shared by another version", () => {
    const only = rangeVersion({ id: 1, version_index: 1, workflow_id: 10, run_id: 100, head_sha: "aaaaaaa1111111" })

    render(
      <DiffReviewVersionSelector
        latestVersionId={1}
        onChange={() => {}}
        selectedVersionId={1}
        versions={[ only ]}
      />
    )

    expect(screen.getByText("RUN-100")).toBeInTheDocument()
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
