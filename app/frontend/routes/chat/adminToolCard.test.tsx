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
        <THead columns={["Run", "GitHub installation ID"]} />
        <TBody>
          <tr>
            <Td mono primary>
              <a href="/runs/1">RUN-1</a>
            </Td>
            <Td wrap>A long diagnostic message</Td>
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
    const diagnosticCell = screen.getByText("A long diagnostic message").closest("td")
    expect(diagnosticCell).toHaveClass("whitespace-normal", "break-words")
    expect(diagnosticCell?.querySelector(":scope > span")).toHaveClass("min-w-0", "whitespace-normal", "break-words", "[overflow-wrap:anywhere]")
    expect(screen.getByRole("link", { name: "RUN-1" }).closest("td")).toHaveClass("[&_a]:min-h-11")
  })

  it("can keep dense tables stacked until their container is wide enough", () => {
    render(
      <Table responsive="container">
        <THead columns={["Job", "Repair plan"]} />
        <TBody>
          <tr>
            <Td primary>JOB-1</Td>
            <Td wrap>Mark a stale run failed</Td>
          </tr>
        </TBody>
      </Table>
    )

    expect(screen.getByRole("table")).toHaveClass("block", "@[64rem]:table")
    expect(screen.getByRole("table").parentElement).toHaveClass("[container-type:inline-size]")
    expect(screen.getByRole("columnheader", { name: "Job" }).closest("thead")).toHaveClass("hidden", "@[64rem]:table-header-group")
    expect(screen.getByText("JOB-1").closest("td")).toHaveAttribute("data-label", "Job")
    expect(screen.getAllByText("Job").at(-1)).toHaveClass("@[64rem]:hidden")
  })
})
