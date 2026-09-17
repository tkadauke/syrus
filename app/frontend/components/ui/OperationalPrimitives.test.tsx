import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ActivityRow, CodeSurface, Metric, Stat, Timeline, ToolCard } from "@app/components/ui"

describe("operational UI primitives", () => {
  it("renders command code surfaces with copy affordance, overflow semantics, and passthrough props", () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText } })

    render(
      <CodeSurface aria-label="Checkout command" code="syrus checkout JOB-12 --with-a-very-long-branch-name" data-testid="command-surface" mode="command" />
    )

    const surface = screen.getByLabelText("Checkout command")
    expect(surface).toHaveAttribute("data-code-surface-mode", "command")
    expect(surface.className).toContain("bg-surface-inset")
    expect(screen.getByText("syrus checkout JOB-12 --with-a-very-long-branch-name").closest("pre")?.className).toContain("overflow-x-auto")

    fireEvent.click(screen.getByRole("button", { name: "Copy code" }))
    expect(writeText).toHaveBeenCalledWith("syrus checkout JOB-12 --with-a-very-long-branch-name")
  })

  it("renders multiline code surfaces with custom copy slot and contrast-safe token styling", () => {
    render(
      <CodeSurface code={"first line\nsecond line"} copySlot={<button type="button">Copy transcript</button>} maxHeightClassName="max-h-24" mode="multiline" />
    )

    const pre = screen.getByText(/first line/).closest("pre")
    expect(pre?.className).toContain("whitespace-pre-wrap")
    expect(pre?.className).toContain("break-words")
    expect(pre?.className).toContain("overflow-auto")
    expect(pre?.className).toContain("max-h-24")
    expect(pre?.className).toContain("[&_span]:contrast-more:!text-text-primary")
    expect(screen.getByRole("button", { name: "Copy transcript" })).toBeInTheDocument()
  })

  it("renders code text size from the typography token", () => {
    render(<CodeSurface code="bin/rspec" mode="command" />)
    expect(screen.getByText("bin/rspec").closest("pre")?.className).toContain("text-[length:var(--text-caption)]")
  })

  it("renders custom code content while copying the raw code string", () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.assign(navigator, { clipboard: { writeText } })

    render(
      <CodeSurface code="raw ansi output" copyLabel="Copy log">
        <span data-testid="rendered-log">rendered ansi output</span>
      </CodeSurface>
    )

    expect(screen.getByTestId("rendered-log").closest("pre")).toBeInTheDocument()
    expect(screen.queryByText("raw ansi output")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Copy log" }))
    expect(writeText).toHaveBeenCalledWith("raw ansi output")
  })

  it("renders metric and stat groups with variants and passthrough props", () => {
    render(
      <>
        <Metric.Group aria-label="Workflow metrics" columns={3} data-testid="metric-group">
          <Metric.Card description="Last 24h" label="Queued" meta="runs queue" tone="warning" value="12" />
          <Metric.Card data-testid="success-metric" label="Success" tone="success" value="87%" />
        </Metric.Group>
        <Stat.Group aria-label="Job stats" columns={2}>
          <Stat.Card label="Open" value={4} />
        </Stat.Group>
      </>
    )

    expect(screen.getByTestId("metric-group").className).toContain("lg:grid-cols-3")
    expect(screen.getByText("Queued").className).toContain("uppercase")
    expect(screen.getByText("Queued").className).toContain("text-[length:var(--text-caption)]")
    expect(screen.getByText("12").className).toContain("text-warning-text")
    expect(screen.getByText("87%").className).toContain("text-success-text")
    expect(screen.getByText("Open")).toBeInTheDocument()
  })

  it("renders timeline activity rows with aria labels, overflow-safe content, and passthrough props", () => {
    const { container } = render(
      <Timeline.Root aria-label="Workflow events" data-testid="timeline" density="comfortable">
        <ActivityRow
          actions={<button type="button">Retry</button>}
          data-testid="activity-row"
          details={<CodeSurface code="bin/check-migrations" mode="command" />}
          meta="RUN-7"
          timestamp="2m ago"
          title="Migration lint failed"
          tone="danger"
        />
        <ActivityRow title="Follow-up queued" />
      </Timeline.Root>
    )

    expect(screen.getByRole("list", { name: "Workflow events" })).toHaveClass("space-y-3")
    expect(screen.getByTestId("activity-row")).toHaveAttribute("data-testid", "activity-row")
    expect(screen.getByText("Migration lint failed").className).toContain("truncate")
    expect(screen.getByText("Migration lint failed").className).toContain("text-[length:var(--text-body)]")
    expect(screen.getByText("RUN-7").className).toContain("truncate")
    expect(screen.getByText("2m ago").className).toContain("whitespace-nowrap")
    expect(screen.getByText("bin/check-migrations")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument()
    expect(screen.getByText("Follow-up queued")).toBeInTheDocument()
    expect(container.querySelectorAll("[data-timeline-connector='true']")).toHaveLength(1)
  })

  it("suppresses the timeline connector for a single-row timeline", () => {
    const { container } = render(
      <Timeline.Root aria-label="Single event">
        <ActivityRow title="Only event" />
      </Timeline.Root>
    )

    expect(screen.getByText("Only event")).toBeInTheDocument()
    expect(container.querySelector("[data-timeline-connector='true']")).not.toBeInTheDocument()
  })

  it("lets isolated activity rows suppress the connector", () => {
    const { container } = render(<ActivityRow showConnector={false} title="Only event" />)

    expect(screen.getByText("Only event")).toBeInTheDocument()
    expect(container.querySelector("[data-timeline-connector='true']")).not.toBeInTheDocument()
  })

  it("renders tool-card shell parts with tone, aria labels, and passthrough props", () => {
    render(
      <ToolCard.Root aria-label="Read job result" data-testid="tool-card" role="region" tone="info">
        <ToolCard.Header actions={<button type="button">Open</button>} eyebrow="read_job" meta="JOB-12" title="Job loaded" />
        <ToolCard.Body className="custom-body">Status: running</ToolCard.Body>
        <ToolCard.Footer data-testid="tool-footer">1 workflow</ToolCard.Footer>
      </ToolCard.Root>
    )

    expect(screen.getByRole("region", { name: "Read job result" }).className).toContain("before:bg-info-border")
    expect(screen.getByText("read_job").className).toContain("uppercase")
    expect(screen.getByText("Job loaded").className).toContain("text-text-primary")
    expect(screen.getByText("Job loaded").className).toContain("text-[length:var(--text-body)]")
    expect(screen.getByText("JOB-12").className).toContain("text-text-muted")
    expect(screen.getByText("Status: running").className).toContain("custom-body")
    const footerClassName = screen.getByTestId("tool-footer").className
    expect(footerClassName).toContain("border-t-[length:var(--border-width)]")
    // Regression guard: an unscoped border-[length:...] alongside border-t
    // would add a visible border-width to the right/bottom/left edges too,
    // turning the intended top-only divider into a full box border.
    expect(footerClassName).not.toMatch(/\bborder-\[length:var\(--border-width\)\]/)
  })
})
