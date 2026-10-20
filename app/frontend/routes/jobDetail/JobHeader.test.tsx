import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { PlacementConfirmationModal } from "./JobHeader"

function renderModal() {
  const mutate = vi.fn()
  const onClose = vi.fn()
  render(
    <PlacementConfirmationModal
      command={{ mutate, isPending: false } as never}
      onClose={onClose}
      path="/api/v1/app/jobs/7/accept_triage"
      recommendation={{
        profile: "macos_desktop",
        label: "macOS desktop",
        capabilities: { os: ["macos"], arch: ["arm64"] },
        explanation: "The desktop package must be tested on macOS.",
        provenance: "ingestion_classifier",
        compatible_worker_available: true
      }}
    />
  )
  return { mutate, onClose }
}

describe("PlacementConfirmationModal", () => {
  it("shows the exact recommendation and submits either explicit decision", () => {
    const { mutate } = renderModal()

    expect(screen.getByText("macOS desktop")).toBeInTheDocument()
    expect(screen.getByText("os: macos · arch: arm64")).toBeInTheDocument()
    expect(screen.getByText("The desktop package must be tested on macOS.")).toBeInTheDocument()
    expect(screen.getByText("A compatible worker is currently available.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Accept using Linux" }))
    expect(mutate).toHaveBeenCalledWith({ method: "post", path: "/api/v1/app/jobs/7/accept_triage", body: { placement_decision: "linux" } }, expect.any(Object))

    fireEvent.click(screen.getByRole("button", { name: "Accept with suggested placement" }))
    expect(mutate).toHaveBeenCalledWith(
      { method: "post", path: "/api/v1/app/jobs/7/accept_triage", body: { placement_decision: "suggested" } },
      expect.any(Object)
    )
  })

  it("leaves the job unchanged when cancelled", () => {
    const { mutate, onClose } = renderModal()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))

    expect(onClose).toHaveBeenCalledOnce()
    expect(mutate).not.toHaveBeenCalled()
  })
})
