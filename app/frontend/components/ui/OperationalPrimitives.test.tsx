import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ActivityRow, CodeSurface, Metric, Stat, Timeline, ToolCard } from "@app/components/ui"

describe("operational ui primitives", () => {
  it("renders CodeSurface command and multiline modes with copy slots and overflow semantics", () => {
    const onCopy = vi.fn()

    render(
      <>
        <CodeSurface aria-label="Checkout command" copySlot={<button onClick={onCopy}>Copy</button>} data-testid="command" language="bash" mode="command">
          syrus checkout JOB-1
        </CodeSurface>
        <CodeSurface data-testid="log" overflow="wrap">
          <CodeSurface.Token tone="keyword">Started</CodeSurface.Token>
          {"\n"}
          <CodeSurface.Token tone="danger">Failed</CodeSurface.Token>
        </CodeSurface>
      </>
    )

    const command = screen.getByTestId("command")
    expect(command).toHaveAttribute("data-code-surface-mode", "command")
    expect(command).toHaveAttribute("data-code-surface-overflow", "truncate")
    expect(command).toHaveAttribute("data-language", "bash")
    expect(command.className).toContain("bg-code-surface")
    expect(command.className).toContain("whitespace-nowrap")
    expect(command.querySelector("code")?.className).toContain("text-ellipsis")
    fireEvent.click(screen.getByRole("button", { name: "Copy" }))
    expect(onCopy).toHaveBeenCalled()

    const log = screen.getByTestId("log")
    expect(log).toHaveAttribute("data-code-surface-mode", "multiline")
    expect(log).toHaveAttribute("data-code-surface-overflow", "wrap")
    expect(log.className).toContain("whitespace-pre-wrap")
    expect(log.querySelector("pre")?.className).toContain("m-0")
    expect(screen.getByText("Started").className).toContain("text-code-keyword")
    expect(screen.getByText("Failed").className).toContain("text-danger-text")
  })

  it("renders Metric and Stat groups with tone variants and passthrough props", () => {
    render(
      <>
        <Metric.Group aria-label="Queue metrics" data-testid="metrics" density="compact">
          <Metric.Card context="last hour" data-testid="blocked" label="Blocked" tone="warning" trend="+2" value={7} />
        </Metric.Group>
        <Stat.Group aria-label="Run stats" data-testid="stats">
          <Stat.Item data-testid="duration" label="Duration" value="3m 12s" />
        </Stat.Group>
      </>
    )

    expect(screen.getByTestId("metrics").className).toContain("gap-2")
    expect(screen.getByTestId("blocked")).toHaveAttribute("data-metric-tone", "warning")
    expect(screen.getByTestId("blocked").className).toContain("bg-warning-surface")
    expect(screen.getByText("last hour")).toBeInTheDocument()
    expect(screen.getByTestId("stats").tagName).toBe("DL")
    expect(screen.getByText("Duration").tagName).toBe("DT")
    expect(screen.getByText("3m 12s").tagName).toBe("DD")
  })

  it("renders Timeline and ActivityRow semantics with marker labels and actions", () => {
    render(
      <Timeline.Root aria-label="Workflow events" data-testid="timeline" density="compact" role="list">
        <Timeline.Item marker="!" markerLabel="Failed event" role="listitem" tone="danger">
          <ActivityRow.Root actions={<button>Retry</button>} data-testid="activity">
            <ActivityRow.Title>Graders failed</ActivityRow.Title>
            <ActivityRow.Meta>
              <span>RUN-1</span>
              <time dateTime="2026-09-13T10:00:00Z">10:00</time>
            </ActivityRow.Meta>
            <ActivityRow.Body>migration-lint exited 1</ActivityRow.Body>
          </ActivityRow.Root>
        </Timeline.Item>
      </Timeline.Root>
    )

    expect(screen.getByTestId("timeline")).toHaveAttribute("data-timeline-density", "compact")
    expect(screen.getByRole("listitem")).toHaveAttribute("data-timeline-tone", "danger")
    expect(screen.getByRole("img", { name: "Failed event" })).toHaveTextContent("!")
    expect(screen.getByText("Graders failed").className).toContain("text-text-primary")
    expect(screen.getByRole("button", { name: "Retry" })).toBeInTheDocument()
  })

  it("renders ToolCard shells with state, header metadata, sections, badges, and passthrough props", () => {
    render(
      <ToolCard.Root aria-label="Read job result" data-testid="tool-card" role="region" state="succeeded">
        <ToolCard.Header icon="*" meta="1 result" title="Read job" />
        <ToolCard.Body>JOB-1 is approved.</ToolCard.Body>
        <ToolCard.Section title="Details">
          <ToolCard.Badge tone="success">approved</ToolCard.Badge>
        </ToolCard.Section>
      </ToolCard.Root>
    )

    const card = screen.getByRole("region", { name: "Read job result" })
    expect(card).toHaveAttribute("data-tool-card-state", "succeeded")
    expect(card.className).toContain("bg-success-surface")
    expect(screen.getByText("Read job")).toBeInTheDocument()
    expect(screen.getByText("1 result").className).toContain("text-text-muted")
    expect(screen.getByText("Details").className).toContain("uppercase")
    expect(screen.getByText("approved").className).toContain("text-success-text")
  })
})
