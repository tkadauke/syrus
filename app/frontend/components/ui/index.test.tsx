import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import {
  Badge,
  Button,
  Card,
  Checkbox,
  Cluster,
  Input,
  Inline,
  LinkText,
  Modal,
  Notice,
  Page,
  PageHeading,
  PanelMessage,
  Pill,
  Select,
  Section,
  Skeleton,
  Stack,
  StatusPill,
  Surface,
  Text,
  Toggle,
  TonePill,
  Toolbar,
  buttonClasses
} from "@app/components/ui"
import { MemoryRouter } from "react-router-dom"

describe("@app/components/ui", () => {
  it("exposes the stable primitive import surface without changing button behavior", () => {
    render(<Button>Run</Button>)

    const button = screen.getByRole("button", { name: "Run" })
    expect(button).toHaveAttribute("type", "button")
    expect(button.className).toContain("bg-brand")
    expect(buttonClasses("secondary", "sm")).toContain("bg-surface")
  })

  it("preserves form primitive invalid and fullWidth contracts", () => {
    render(
      <>
        <Input aria-label="Name" fullWidth={false} invalid />
        <Select aria-label="Mode" invalid>
          <option>Auto</option>
        </Select>
        <Checkbox label="Required" />
      </>
    )

    expect(screen.getByLabelText("Name")).toHaveAttribute("aria-invalid", "true")
    expect(screen.getByLabelText("Name").className).toContain("w-auto")
    expect(screen.getByLabelText("Mode")).toHaveAttribute("aria-invalid", "true")
    expect(screen.getByLabelText("Mode").className).toContain("w-full")
    expect(screen.getByLabelText("Required")).toHaveAttribute("type", "checkbox")
  })

  it("preserves the controlled switch contract for Toggle", () => {
    const onChange = vi.fn()
    render(<Toggle checked={false} label="Enabled" onChange={onChange} />)

    fireEvent.click(screen.getByRole("switch", { name: "Enabled" }))

    expect(onChange).toHaveBeenCalledWith(true)
  })

  it("preserves surface, heading, and pill primitives for migration callers", () => {
    render(
      <>
        <PageHeading>Dashboard</PageHeading>
        <Card data-testid="card">Panel</Card>
        <Skeleton className="h-4" data-testid="skeleton" />
        <PanelMessage tone="warning">Careful</PanelMessage>
        <StatusPill state="running" />
        <StatusPill state="succeeded" />
        <TonePill tone="amber">Queued</TonePill>
      </>
    )

    expect(screen.getByRole("heading", { level: 1, name: "Dashboard" })).toBeInTheDocument()
    expect(screen.getByTestId("card").className).toContain("border-border")
    expect(screen.getByTestId("skeleton").className).toContain("animate-pulse")
    expect(screen.getByText("Careful").parentElement?.className).toContain("border-warning-border")
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("succeeded").closest("[data-status-pill]")?.className).toContain("bg-success-surface")
    expect(screen.getByText("Queued")).toBeInTheDocument()
  })

  it("exports Surface with tokenized variants, passthrough props, and className escape hatches", () => {
    const onClick = vi.fn()
    render(
      <>
        <Surface aria-label="Repository settings" className="min-h-20" data-testid="surface" onClick={onClick} role="region" variant="raised">
          Settings
        </Surface>
        <Surface data-testid="danger" padding="sm" variant="danger">Failed</Surface>
      </>
    )

    const surface = screen.getByRole("region", { name: "Repository settings" })
    fireEvent.click(surface)
    expect(onClick).toHaveBeenCalled()
    expect(surface.className).toContain("bg-surface")
    expect(surface.className).toContain("shadow-[var(--shadow-panel)]")
    expect(surface.className).toContain("min-h-20")
    expect(screen.getByTestId("danger").className).toContain("bg-danger-surface")
  })

  it("exports Text variants and semantic tone classes without raw gray output", () => {
    render(
      <>
        <Text data-testid="body">Normal</Text>
        <Text data-testid="muted" muted>Muted</Text>
        <Text as="code" data-testid="mono" variant="mono">JOB-1</Text>
        <Text data-testid="danger" tone="danger">Failed</Text>
      </>
    )

    expect(screen.getByTestId("body").className).toContain("text-text-primary")
    expect(screen.getByTestId("muted").className).toContain("text-text-muted")
    expect(screen.getByTestId("mono").tagName).toBe("CODE")
    expect(screen.getByTestId("mono").className).toContain("font-mono")
    expect(screen.getByTestId("danger").className).toContain("text-danger-text")
    expect(screen.getByTestId("muted").className).not.toMatch(/\btext-gray-/)
  })

  it("exports Stack, Inline, Cluster, and Toolbar layout helpers with passthrough props", () => {
    render(
      <>
        <Stack className="custom-stack" data-testid="stack" gap="lg" />
        <Inline aria-label="metadata" data-testid="inline" justify="between" wrap />
        <Cluster data-testid="cluster" gap="xs" />
        <Toolbar aria-label="Actions" data-testid="toolbar" />
      </>
    )

    expect(screen.getByTestId("stack").className).toContain("space-y-4")
    expect(screen.getByTestId("stack").className).toContain("custom-stack")
    expect(screen.getByTestId("inline").className).toContain("flex-wrap")
    expect(screen.getByTestId("inline")).toHaveAttribute("aria-label", "metadata")
    expect(screen.getByTestId("cluster").className).toContain("gap-1.5")
    expect(screen.getByRole("toolbar", { name: "Actions" })).toBeInTheDocument()
  })

  it("exports Page and Section compound primitives", () => {
    render(
      <Page.Root aria-label="Dashboard page" size="wide">
        <Page.Header>
          <Page.HeadingGroup>
            <Page.Title>Dashboard</Page.Title>
            <Page.Description>Queue and work state</Page.Description>
          </Page.HeadingGroup>
          <Page.Actions><Button>New Job</Button></Page.Actions>
        </Page.Header>
        <Section.Root aria-label="Work attempts" divided tone="subtle">
          <Section.Header>
            <Section.Title>Attempts</Section.Title>
            <Section.Actions><Button size="sm">Retry</Button></Section.Actions>
          </Section.Header>
          <Section.Body padding="sm"><Text muted>No attempts yet.</Text></Section.Body>
        </Section.Root>
      </Page.Root>
    )

    expect(screen.getByRole("main", { name: "Dashboard page" }).className).toContain("max-w-[96rem]")
    expect(screen.getByRole("heading", { level: 1, name: "Dashboard" }).className).toContain("text-[length:var(--text-page-title)]")
    expect(screen.getByRole("heading", { level: 1, name: "Dashboard" }).closest("header")).toBeInTheDocument()
    expect(screen.getByRole("region", { name: "Work attempts" }).className).toContain("bg-surface-subtle")
    expect(screen.getByRole("region", { name: "Work attempts" })).toHaveAttribute("data-section-divided", "true")
  })

  it("exports LinkText for router and external anchor links", () => {
    render(
      <MemoryRouter>
        <LinkText to="/jobs/1">JOB-1</LinkText>
        <LinkText external href="https://example.test">External</LinkText>
      </MemoryRouter>
    )

    expect(screen.getByRole("link", { name: "JOB-1" })).toHaveAttribute("href", "/jobs/1")
    expect(screen.getByRole("link", { name: "JOB-1" }).className).toContain("text-link")
    expect(screen.getByRole("link", { name: "External" })).toHaveAttribute("target", "_blank")
    expect(screen.getByRole("link", { name: "External" })).toHaveAttribute("rel", "noreferrer")
  })

  it("exports Notice, Pill, and Badge with semantic tones and accessibility passthrough", () => {
    render(
      <>
        <Notice aria-live="polite" title="Landing queue is blocked" tone="warning">
          A dependency is waiting.
        </Notice>
        <Notice contentClassName="flex justify-between" title="Repository health" tone="danger">
          <span>Broken</span>
          <button>Repair</button>
        </Notice>
        <Pill active aria-label="Running" tone="info">Running</Pill>
        <Badge data-testid="badge" tone="success">primary</Badge>
      </>
    )

    expect(screen.getByText("Landing queue is blocked").closest("div")).toHaveAttribute("aria-live", "polite")
    expect(screen.getByText("Landing queue is blocked").closest("div")?.className).toContain("bg-warning-surface")
    expect(screen.getByRole("button", { name: "Repair" }).parentElement?.className).toContain("flex")
    expect(screen.getByRole("button", { name: "Repair" }).parentElement?.className).toContain("justify-between")
    expect(screen.getByLabelText("Running").className).toContain("bg-info-surface")
    expect(screen.getByLabelText("Running").querySelector("[data-running-spinner]")).toBeInTheDocument()
    expect(screen.getByTestId("badge").className).toContain("rounded-[var(--radius-control)]")
    expect(screen.getByTestId("badge").className).not.toMatch(/\bbg-green-/)
  })

  it("preserves Modal portal and close behavior", () => {
    const onClose = vi.fn()
    render(
      <Modal label="Confirm" onClose={onClose} open>
        <button>Inside</button>
      </Modal>
    )

    const dialog = screen.getByRole("dialog", { name: "Confirm" })
    expect(dialog).toBeInTheDocument()

    fireEvent.keyDown(document, { key: "Escape" })
    expect(onClose).toHaveBeenCalled()
  })
})
