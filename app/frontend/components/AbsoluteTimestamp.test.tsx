import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { TimeZoneProvider } from "../contexts/TimeZoneContext"
import { AbsoluteTimestamp } from "./AbsoluteTimestamp"

vi.mock("../i18n", () => ({ default: { language: "en" } }))

describe("AbsoluteTimestamp", () => {
  it("shows one zoned value when user and server zones match", () => {
    render(
      <TimeZoneProvider value={{ user: "UTC", server: "UTC" }}>
        <AbsoluteTimestamp value="2026-01-02T12:00:00Z" />
      </TimeZoneProvider>
    )
    const time = screen.getByText(/Jan 2, 2026/)
    expect(time).not.toHaveTextContent("Your time")
    expect(time).toHaveAttribute("datetime", "2026-01-02T12:00:00.000Z")
  })

  it("labels user and server values when zones differ", () => {
    render(
      <TimeZoneProvider value={{ user: "America/New_York", server: "Europe/Berlin" }}>
        <AbsoluteTimestamp value="2026-01-02T12:00:00Z" />
      </TimeZoneProvider>
    )
    expect(screen.getByText(/Your time:/)).toHaveTextContent(/Server time:/)
  })
})
