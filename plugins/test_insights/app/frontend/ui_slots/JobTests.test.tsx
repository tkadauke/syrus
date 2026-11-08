import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import { jsonResponse } from "@app/testSupport"
import JobTests from "./JobTests"

afterEach(async () => {
  vi.restoreAllMocks()
  await i18n.changeLanguage("en")
})

describe("JobTests", () => {
  it("renders localized plural test result counts", async () => {
    await i18n.changeLanguage("de")
    vi.spyOn(window, "fetch").mockImplementation(async () =>
      jsonResponse({
        job_id: 42,
        workflow_id: 7,
        test_runs: [
          {
            id: 1,
            grader_name: "rspec",
            run_id: 9,
            total_count: 6,
            passed_count: 2,
            failed_count: 1,
            skipped_count: 1,
            error_count: 2,
            duration_ms: null,
            suites: [
              {
                suite_name: "spec/models/job_spec.rb",
                total_count: 6,
                passed_count: 2,
                failed_count: 1,
                skipped_count: 1,
                error_count: 2,
                test_cases: []
              }
            ]
          }
        ]
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={client}>
        <JobTests job={{ id: 42 }} />
      </QueryClientProvider>
    )

    expect(await screen.findAllByText("1 fehlgeschlagen")).toHaveLength(1)
    expect(screen.getAllByText("2 Fehler")).toHaveLength(1)
    expect(screen.getAllByText("2 bestanden")).toHaveLength(1)
    expect(screen.getAllByText("1 übersprungen")).toHaveLength(1)
    expect(screen.getByText("6 gesamt")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Details" }))

    await waitFor(() => expect(window.fetch).toHaveBeenCalledWith("/api/v1/app/jobs/42/test_results?grader_name=rspec&include_suites=true", expect.anything()))
    expect(await screen.findByText("spec/models/job_spec.rb")).toBeInTheDocument()
  })
})
