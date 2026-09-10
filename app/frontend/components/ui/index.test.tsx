import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import {
  Button,
  Card,
  Checkbox,
  Input,
  Modal,
  PageHeading,
  PanelMessage,
  Select,
  Skeleton,
  StatusPill,
  Toggle,
  TonePill,
  buttonClasses
} from "@app/components/ui"

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
        <TonePill tone="amber">Queued</TonePill>
      </>
    )

    expect(screen.getByRole("heading", { level: 1, name: "Dashboard" })).toBeInTheDocument()
    expect(screen.getByTestId("card").className).toContain("border-border")
    expect(screen.getByTestId("skeleton").className).toContain("animate-pulse")
    expect(screen.getByText("Careful").className).toContain("border-amber-200")
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("Queued")).toBeInTheDocument()
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
