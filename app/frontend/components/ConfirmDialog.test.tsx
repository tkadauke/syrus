import { render, screen, fireEvent } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ConfirmDialog, type ConfirmDialogProps } from "./ConfirmDialog"

function renderDialog(props: Partial<ConfirmDialogProps> = {}) {
  return render(
    <ConfirmDialog
      open={props.open ?? true}
      message={props.message ?? "Are you sure?"}
      confirmLabel={props.confirmLabel}
      cancelLabel={props.cancelLabel}
      destructive={props.destructive}
      onConfirm={props.onConfirm ?? vi.fn()}
      onCancel={props.onCancel ?? vi.fn()}
    />
  )
}

describe("ConfirmDialog", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders the message", () => {
    renderDialog({ message: "Delete this item?" })
    expect(screen.getByText("Delete this item?")).toBeInTheDocument()
  })

  it("renders default Confirm and Cancel labels", () => {
    renderDialog()
    expect(screen.getByRole("button", { name: "Confirm" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()
  })

  it("renders custom button labels", () => {
    renderDialog({ confirmLabel: "Delete", cancelLabel: "Never mind" })
    expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Never mind" })).toBeInTheDocument()
  })

  it("calls onConfirm when the confirm button is clicked", () => {
    const onConfirm = vi.fn()
    renderDialog({ onConfirm })
    fireEvent.click(screen.getByRole("button", { name: "Confirm" }))
    expect(onConfirm).toHaveBeenCalledTimes(1)
  })

  it("calls onCancel when the cancel button is clicked", () => {
    const onCancel = vi.fn()
    renderDialog({ onCancel })
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it("calls onCancel when ESC is pressed", () => {
    const onCancel = vi.fn()
    renderDialog({ onCancel })
    fireEvent.keyDown(document, { key: "Escape" })
    expect(onCancel).toHaveBeenCalledTimes(1)
  })

  it("does not render when open is false", () => {
    renderDialog({ open: false })
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("renders a dialog with aria-modal", () => {
    renderDialog()
    expect(screen.getByRole("dialog")).toHaveAttribute("aria-modal", "true")
  })

  it("applies red confirm button when destructive is true", () => {
    renderDialog({ destructive: true })
    expect(screen.getByRole("button", { name: "Confirm" }).className).toContain("bg-red-600")
  })

  it("applies blue confirm button when destructive is false", () => {
    renderDialog({ destructive: false })
    expect(screen.getByRole("button", { name: "Confirm" }).className).toContain("bg-blue-600")
  })
})
