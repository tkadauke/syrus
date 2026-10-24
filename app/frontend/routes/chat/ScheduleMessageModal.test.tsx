import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ScheduleMessageModal } from "./ScheduleMessageModal"

describe("ScheduleMessageModal", () => {
  it("renders localized chrome and preserves the authored message", () => {
    render(<ScheduleMessageModal initialBody="Keep this exactly" onCancel={vi.fn()} onSchedule={vi.fn()} />)

    expect(screen.getByRole("heading", { name: "Schedule Message" })).toBeInTheDocument()
    expect(screen.getByDisplayValue("Keep this exactly")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Schedule" })).toBeInTheDocument()
  })

  it("uses localized validation copy", () => {
    render(<ScheduleMessageModal onCancel={vi.fn()} onSchedule={vi.fn()} />)

    fireEvent.click(screen.getByRole("button", { name: "Schedule" }))

    expect(screen.getByText("Enter a time like 30m, 2h, tomorrow 9am, or 14:30.")).toBeInTheDocument()
  })
})
