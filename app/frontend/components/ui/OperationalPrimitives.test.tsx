import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ActivityRow, Button, CodeSurface, Metric, MetricGroup, Stat, StatGroup, Timeline, ToolCard } from "@app/components/ui"

describe("operational UI primitives", () => {
  it("renders CodeSurface command mode with overflow semantics, copy slot, aria labels, and passthrough props", () => {
    render(
      <CodeSurface
        aria-label="Run command"
        className="custom-code"
        code="bundle exec rspec spec/models/job_spec.rb"
        copySlot={<Button aria-label="Copy command" size="icon">C</Button>}
        data-testid="command-surface"
        mode="command"
      />
    )

    const surface = screen.getByLabelText("Run command")
    expect(surface.tagName).toBe("PRE")
    expect(surface).toHaveAttribute("data-code-surface-mode", "command")
    expect(surface.className).toContain("overflow-x-auto")
    expect(surface.className).toContain("whitespace-pre")
    expect(surface.className).toContain("custom-code")
    expect(screen.getByRole("button", { name: "Copy command" })).toBeInTheDocument()
  })

  it("renders CodeSurface multiline mode with wrapping overflow and contrast-safe semantic tone classes", () => {
    render(
      <CodeSurface aria-label="Failure log" code={"error\nstack trace"} mode="multiline" tone="danger" />
    )

    const surface = screen.getByLabelText("Failure log")
    expect(surface).toHaveTextContent("stack trace")
    expect(surface.className).toContain("whitespace-pre-wrap")
    expect(surface.className).toContain("overflow-auto")
    expect(surface.className).toContain("bg-danger-surface")
    expect(surface.className).toContain("text-danger-text")
    expect(surface.className).not.toMatch(/\btext-gray-/)
  })

  it("renders Metric and Stat group/card variants with passthrough props", () => {
    const onClick = vi.fn()
    render(
      <>
        <MetricGroup aria-label="Queue metrics" data-testid="metric-group" columns={3}>
          <Metric data-testid="metric" detail="2 blocked" label="Running" onClick={onClick} tone="info" value="12" />
        </MetricGroup>
        <StatGroup aria-label="Worker stats" columns={2}>
          <Stat density="compact" label="Idle" tone="success" value="4" />
        </StatGroup>
      </>
    )

    expect(screen.getByTestId("metric-group").className).toContain("lg:grid-cols-3")
    expect(screen.getByTestId("metric")).toHaveAttribute("data-metric", "true")
    expect(screen.getByTestId("metric").className).toContain("bg-info-surface")
    expect(screen.getByText("12")).toHaveAttribute("title", "12")
    screen.getByTestId("metric").click()
    expect(onClick).toHaveBeenCalled()
    expect(screen.getByText("Idle")).toBeInTheDocument()
  })

  it("renders Timeline and ActivityRow with semantic list structure, row tones, actions, and passthrough props", () => {
    render(
      <Timeline aria-label="Workflow activity" data-testid="timeline" density="compact">
        <ActivityRow
          actions={<Button size="sm">Open</Button>}
          data-testid="activity-row"
          description="Prepare completed and implement started."
          eyebrow="STEP-1"
          meta="2m ago"
          title="Implement running"
          tone="warning"
        />
      </Timeline>
    )

    expect(screen.getByRole("list", { name: "Workflow activity" })).toHaveAttribute("data-timeline", "true")
    expect(screen.getByTestId("timeline").className).toContain("text-xs")
    expect(screen.getByRole("listitem")).toHaveAttribute("data-activity-row", "true")
    expect(screen.getByTestId("activity-row").querySelector("[data-activity-row-marker]")?.className).toContain("bg-warning-surface")
    expect(screen.getByText("Prepare completed and implement started.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Open" })).toBeInTheDocument()
  })

  it("renders ToolCard shell slots and section primitives for core and plugin cards", () => {
    render(
      <ToolCard
        actions={<Button size="sm">Retry</Button>}
        aria-label="Tool result"
        data-testid="tool-card"
        footer="Raw details available"
        meta={<span>read_job</span>}
        summary="Loaded current job state."
        title="Read job"
        variant="raised"
      >
        <ToolCard.Section title="Result">
          <p>JOB-1 is running.</p>
        </ToolCard.Section>
      </ToolCard>
    )

    const card = screen.getByLabelText("Tool result")
    expect(card).toHaveAttribute("data-tool-card-shell", "true")
    expect(card.className).toContain("shadow-[var(--shadow-panel)]")
    expect(screen.getByText("Read job")).toBeInTheDocument()
    expect(screen.getByText("Loaded current job state.")).toBeInTheDocument()
    expect(screen.getByText("read_job")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Result" })).toBeInTheDocument()
    expect(screen.getByText("Raw details available")).toBeInTheDocument()
  })
})
