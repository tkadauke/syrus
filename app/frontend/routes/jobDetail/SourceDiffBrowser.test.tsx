import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { stubVirtualizerMeasurements } from "../../test/virtualizerMeasurements"
import { jsonResponse } from "../../testSupport"
import { DEFAULT_REVIEW_DIFF_SETTINGS } from "../../api/reviewDiffSettings"
import type { JobSourceDiffPayload } from "../../api/jobs"
import { SourceDiffBrowser } from "./SourceBrowser"

stubVirtualizerMeasurements()

vi.mock("./DiffReviewFeedback", () => ({
  useDiffReviewFeedback: () => ({
    commentCounts: {},
    diffThreads: {},
    panel: null,
    composingBody: "",
    composingDiscussError: null,
    composingDiscussPending: false,
    composingError: null,
    composingPending: false,
    composingSelection: null,
    editingThreadBody: "",
    editingThreadId: null,
    selectedCommentPath: null,
    onCancelComposing: vi.fn(),
    onCancelEditThread: vi.fn(),
    onChangeComposingBody: vi.fn(),
    onChangeEditingThreadBody: vi.fn(),
    onCommentLine: vi.fn(),
    onDiscussComposing: vi.fn(),
    onSaveComposing: vi.fn(),
    onSaveEditThread: vi.fn(),
    onStartEditThread: vi.fn()
  })
}))

function renderBrowser(payload: JobSourceDiffPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <SourceDiffBrowser
        canReviewDiff
        diffAnnotations={null}
        mode="diff"
        onModeChange={() => {}}
        onSelectBaseRef={() => {}}
        onSelectHeadRef={() => {}}
        payload={payload}
        showDiffToggle
      />
    </QueryClientProvider>
  )
  return client
}

function payload(overrides: Partial<JobSourceDiffPayload> = {}): JobSourceDiffPayload {
  return {
    job_id: 42,
    base_ref: "main",
    head_ref: "branch",
    base_sha: "base-sha",
    head_sha: "head-sha",
    merge_base_sha: "base-sha",
    default_ref: "main",
    branch_commits: [],
    truncated: false,
    diff_error: null,
    version: null,
    versions: [],
    review_annotations: {
      annotations: {},
      ranges: {},
      panels: [],
      actions: [],
      counts: []
    },
    coverage_annotations: {},
    files: [
      {
        additions: 1,
        deletions: 0,
        path: "app/models/user.rb",
        status: "modified",
        patch: [
          "diff --git a/app/models/user.rb b/app/models/user.rb",
          "--- a/app/models/user.rb",
          "+++ b/app/models/user.rb",
          "@@ -1,1 +1,1 @@",
          "+new"
        ].join("\n")
      }
    ],
    ...overrides
  }
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("SourceDiffBrowser", () => {
  it("exposes and renders PR coverage metric gutters when the source diff payload has annotations", async () => {
    vi.spyOn(window, "fetch").mockImplementation(async (_url, init) => {
      const patch = init?.method === "PATCH" ? JSON.parse(String(init.body)).review_diff_settings : {}
      return jsonResponse({
        review_diff_settings: {
          ...DEFAULT_REVIEW_DIFF_SETTINGS,
          metric_gutter: "off",
          ...patch
        }
      })
    })

    renderBrowser(payload({
      coverage_annotations: {
        "app/models/user.rb": { "1": "covered" }
      }
    }))

    fireEvent.click(await screen.findByRole("button", { name: /app\/models\/user\.rb/ }))
    fireEvent.click(await screen.findByRole("button", { name: "Review settings" }))
    const selector = screen.getByLabelText("Metric gutter")

    expect(selector).toHaveValue("off")
    expect(within(selector).getByRole("option", { name: "PR coverage" })).toBeInTheDocument()
    expect(screen.queryByTestId("diff-metric-gutter-cell")).not.toBeInTheDocument()

    fireEvent.change(selector, { target: { value: "coverage.pr" } })

    await waitFor(() => {
      expect(screen.getByTitle("Changed line covered by tests")).toHaveClass("bg-success")
    })
  })

  it("keeps metric gutter controls hidden when source diff coverage annotations are empty", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      review_diff_settings: DEFAULT_REVIEW_DIFF_SETTINGS
    }))

    renderBrowser(payload())

    fireEvent.click(await screen.findByRole("button", { name: "Review settings" }))

    expect(screen.queryByLabelText("Metric gutter")).not.toBeInTheDocument()
  })
})
