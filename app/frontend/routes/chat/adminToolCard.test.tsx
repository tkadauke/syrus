import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { Table, TBody, Td, THead } from "./adminToolCard"

describe("admin tool card table", () => {
  it("preserves the existing desktop table markup by default", () => {
    render(
      <Table>
        <THead columns={["Run", "State"]} />
        <TBody>
          <tr>
            <Td mono>RUN-1</Td>
            <Td>running</Td>
          </tr>
        </TBody>
      </Table>
    )

    expect(screen.getByRole("table")).toBeInTheDocument()
    expect(screen.getByRole("columnheader", { name: "Run" })).toBeInTheDocument()
    expect(screen.getByText("RUN-1")).not.toHaveAttribute("data-label")
  })

  it("adds mobile labels, wrapping, prominence, and touch targets when opted in", () => {
    render(
      <Table responsive>
        <THead columns={["Run", "Message"]} />
        <TBody>
          <tr>
            <Td label="Run" mono primary>
              <a href="/runs/1">RUN-1</a>
            </Td>
            <Td label="Message" wrap>
              A long diagnostic message
            </Td>
          </tr>
        </TBody>
      </Table>
    )

    expect(screen.getByRole("table")).toHaveClass("block", "sm:table")
    expect(screen.getByRole("columnheader", { name: "Run" }).closest("thead")).toHaveClass("hidden", "sm:table-header-group")
    const primaryCell = screen.getByText("RUN-1").closest("td")
    expect(primaryCell).toHaveAttribute("data-label", "Run")
    expect(primaryCell).toHaveTextContent("RunRUN-1")
    expect(primaryCell).toHaveClass("font-semibold")
    expect(screen.getByText("A long diagnostic message")).toHaveClass("whitespace-normal", "break-words")
    expect(screen.getByRole("link", { name: "RUN-1" }).closest("td")).toHaveClass("[&_a]:min-h-11")
  })
})
