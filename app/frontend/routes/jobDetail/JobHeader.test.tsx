import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { PlacementConfirmationModal, PlacementOverrideModal } from "./JobHeader"

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

describe("PlacementOverrideModal", () => {
  it("shows distinct profiles, before/after placement, and requires an audit reason", () => {
    const mutate = vi.fn()
    render(
      <PlacementOverrideModal
        command={{ mutate, isPending: false } as never}
        job={
          {
            id: 7,
            entity_revision: 12,
            planned_execution: { capabilities: { os: ["macos"], arch: ["arm64"], toolchain: ["xcode"], runtime: ["ios_simulator"] } },
            planned_execution_override: {
              eligible: true,
              current_profile: "ios_xcode",
              profiles: [
                { name: "linux", label: "Linux", capabilities: { os: ["linux"] } },
                { name: "macos_desktop", label: "macOS desktop", capabilities: { os: ["macos"], arch: ["arm64"] } },
                { name: "ios_xcode", label: "iOS / Xcode", capabilities: { os: ["macos"], toolchain: ["xcode"], runtime: ["ios_simulator"] } }
              ],
              worker_availability: { linux: true, macos_desktop: false, ios_xcode: true },
              latest_audit: null
            }
          } as never
        }
        onClose={vi.fn()}
        path="/api/v1/app/jobs/7/override_planned_execution"
      />
    )

    expect(screen.getByRole("option", { name: "macOS desktop" })).toBeInTheDocument()
    expect(screen.getByRole("option", { name: "iOS / Xcode" })).toBeInTheDocument()
    const submit = screen.getByRole("button", { name: "Confirm placement change" })
    expect(submit).toBeDisabled()
    fireEvent.change(screen.getByLabelText("Execution profile"), { target: { value: "linux" } })
    fireEvent.change(screen.getByLabelText("Audit reason"), { target: { value: "Classifier selected the mobile bundle." } })
    fireEvent.click(submit)
    expect(mutate).toHaveBeenCalledWith(
      {
        method: "post",
        path: "/api/v1/app/jobs/7/override_planned_execution",
        body: { profile: "linux", reason: "Classifier selected the mobile bundle.", entity_revision: 12 }
      },
      expect.any(Object)
    )
  })
})
