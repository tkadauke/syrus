import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { QuestionEagernessFields } from "./QuestionEagernessFields"

describe("QuestionEagernessFields", () => {
  it("snaps to the five named levels and edits the optional timeout", () => {
    const onChange = vi.fn()
    render(<QuestionEagernessFields eagerness="balanced" onChange={onChange} timeoutSeconds={3600} />)

    fireEvent.change(screen.getByLabelText("Question eagerness level"), { target: { value: "4" } })
    expect(onChange).toHaveBeenCalledWith("collaborative", 3600)

    fireEvent.change(screen.getByLabelText("Answer timeout (minutes)"), { target: { value: "90" } })
    expect(onChange).toHaveBeenCalledWith("balanced", 5400)
  })

  it("bounds the timeout input to the range the server accepts", () => {
    render(<QuestionEagernessFields eagerness="balanced" onChange={vi.fn()} timeoutSeconds={null} />)

    const input = screen.getByLabelText("Answer timeout (minutes)")
    expect(input).toHaveAttribute("min", "60")
    expect(input).toHaveAttribute("max", "40320")
    expect(screen.getByText(/60–40320 minutes \(1 hour to 4 weeks\)/)).toBeInTheDocument()
  })

  it("supports inheriting the parent setting", () => {
    const onChange = vi.fn()
    render(<QuestionEagernessFields eagerness="autonomous" onChange={onChange} timeoutSeconds={null} />)
    fireEvent.change(screen.getByLabelText("Question eagerness level"), { target: { value: "0" } })
    expect(onChange).toHaveBeenCalledWith(null, null)
  })
})
