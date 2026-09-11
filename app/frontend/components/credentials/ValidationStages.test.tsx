import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { ValidationStages, type ValidationStage } from "./ValidationStages"

type Key = "format" | "reach" | "video"

const labels: Record<Key, string> = {
  format: "Key looks well-formed",
  reach: "Google accepts the key",
  video: "Video-capable model available"
}

function stages(overrides: Partial<Record<Key, ValidationStage<Key>>> = {}): ValidationStage<Key>[] {
  return (["format", "reach", "video"] as const).map((key) => overrides[key] ?? { key, status: "pending" as const })
}

describe("ValidationStages", () => {
  it("renders the list and each stage under the testid prefix contract", () => {
    render(<ValidationStages labels={labels} stages={stages()} testIdPrefix="gemini" />)

    expect(screen.getByTestId("gemini-validation-stages")).toBeInTheDocument()
    expect(screen.getByTestId("gemini-stage-format")).toHaveAttribute("data-status", "pending")
    expect(screen.getByTestId("gemini-stage-reach")).toHaveAttribute("data-status", "pending")
    expect(screen.getByTestId("gemini-stage-video")).toHaveAttribute("data-status", "pending")
  })

  it("reflects each stage's status in data-status and shows the label", () => {
    render(
      <ValidationStages
        labels={labels}
        stages={stages({
          format: { key: "format", status: "ok" },
          reach: { key: "reach", status: "running" },
          video: { key: "video", status: "failed" }
        })}
        testIdPrefix="probe"
      />
    )

    expect(screen.getByTestId("probe-stage-format")).toHaveAttribute("data-status", "ok")
    expect(screen.getByTestId("probe-stage-reach")).toHaveAttribute("data-status", "running")
    expect(screen.getByTestId("probe-stage-video")).toHaveAttribute("data-status", "failed")
    expect(screen.getByText("Key looks well-formed")).toBeInTheDocument()
    expect(screen.getByText("Google accepts the key")).toBeInTheDocument()
  })

  it("renders the optional detail next to a stage label", () => {
    render(<ValidationStages labels={labels} stages={stages({ video: { key: "video", status: "ok", detail: "gemini-2.5-flash" } })} testIdPrefix="gemini" />)

    expect(screen.getByText("(gemini-2.5-flash)")).toBeInTheDocument()
  })
})
