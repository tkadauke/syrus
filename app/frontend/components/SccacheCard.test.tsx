import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { JobSccacheInfo } from "../api/jobs"
import { SccacheCard } from "./SccacheCard"

const fullSccache: JobSccacheInfo = {
  workflow_id: 1,
  run_id: 42,
  step_kind: "grader",
  label: "coverage",
  iteration: 2,
  captured_at: "2026-08-20T10:05:00Z",
  summary: {
    hits: 9,
    misses: 3,
    hit_rate: 75.0,
    cache_size: 209_715_200,
    max_cache_size: 1_073_741_824,
    cache_location: "S3, bucket: syrus-build-cache"
  }
}

describe("SccacheCard", () => {
  it("renders hit/miss/hit-rate badges when counts are present", () => {
    render(<SccacheCard sccache={fullSccache} />)

    const badges = screen.getByTestId("sccache-summary").querySelectorAll("[data-status-pill]")
    expect(badges).toHaveLength(3)
    expect(badges[0]).toHaveTextContent("9")
    expect(badges[1]).toHaveTextContent("3")
    expect(badges[2]).toHaveTextContent("75.0%")
  })

  it("renders a fallback message instead of badges when hit/miss counts are unavailable", () => {
    render(<SccacheCard sccache={{ ...fullSccache, summary: { hits: null, misses: null, hit_rate: null, cache_size: null, max_cache_size: null, cache_location: null } }} />)

    expect(screen.queryByTestId("sccache-summary")).not.toBeInTheDocument()
    expect(screen.getByText(/not reported/i)).toBeInTheDocument()
  })

  it("formats a numeric cache size as human-readable bytes", () => {
    render(<SccacheCard sccache={fullSccache} />)

    expect(screen.getByText(/200\.0 MB/)).toBeInTheDocument()
  })

  it("renders a string cache size verbatim", () => {
    render(<SccacheCard sccache={{ ...fullSccache, summary: { ...fullSccache.summary, cache_size: "150 MiB", max_cache_size: null } }} />)

    expect(screen.getByText(/150 MiB/)).toBeInTheDocument()
  })

  it("omits the cache size line when neither cache_size nor max_cache_size is present", () => {
    render(<SccacheCard sccache={{ ...fullSccache, summary: { ...fullSccache.summary, cache_size: null, max_cache_size: null } }} />)

    expect(screen.queryByText(/Cache size/)).not.toBeInTheDocument()
  })

  it("renders the cache location when present", () => {
    render(<SccacheCard sccache={fullSccache} />)

    expect(screen.getByText(/S3, bucket: syrus-build-cache/)).toBeInTheDocument()
  })

  it("omits the cache location line when absent", () => {
    render(<SccacheCard sccache={{ ...fullSccache, summary: { ...fullSccache.summary, cache_location: null } }} />)

    expect(screen.queryByText(/Location/)).not.toBeInTheDocument()
  })

  it("shows the capture context (label, step kind, iteration)", () => {
    render(<SccacheCard sccache={fullSccache} />)

    expect(screen.getByText(/coverage/)).toBeInTheDocument()
    expect(screen.getByText(/grader/)).toBeInTheDocument()
    expect(screen.getByText(/iteration 2/)).toBeInTheDocument()
  })
})
