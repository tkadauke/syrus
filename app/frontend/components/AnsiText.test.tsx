import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { AnsiText, parseAnsiText } from "./AnsiText"

describe("AnsiText", () => {
  it("renders SGR colors as styled spans without visible escape codes", () => {
    render(<pre><AnsiText text={"RUN \u001b[32mpassed\u001b[39m and \u001b[33mwarned\u001b[39m"} /></pre>)

    expect(screen.getByText("passed")).toHaveClass("text-emerald-700")
    expect(screen.getByText("warned")).toHaveClass("text-amber-700")
    expect(screen.getByText(/RUN/)).not.toHaveTextContent("\u001b[32m")
  })

  it("renders SGR blue as a literal blue, not the brand-remapped blue-* scale", () => {
    // Tailwind's `blue` scale is remapped to the brand terracotta accent
    // (config/tailwind.config.js), so a raw `text-blue-*` class here would
    // render brand-colored text instead of literal ANSI blue.
    render(<pre><AnsiText text={"\u001b[34minfo\u001b[39m"} /></pre>)

    expect(screen.getByText("info")).toHaveClass("text-sky-700")
    expect(screen.getByText("info")).not.toHaveClass("text-blue-700")
  })

  it("supports intensity and reset directives", () => {
    render(<pre><AnsiText text={"\u001b[1mbold\u001b[22m normal \u001b[2mdim\u001b[0m"} /></pre>)

    expect(screen.getByText("bold")).toHaveClass("font-semibold")
    expect(screen.getByText("dim")).toHaveClass("opacity-70")
    expect(screen.getByText(/normal/)).not.toHaveClass("font-semibold")
  })

  it("strips unsupported control sequences", () => {
    const segments = parseAnsiText("before\u001b[2Kafter\u001b[?25l")

    expect(segments.map((segment) => segment.text).join("")).toBe("beforeafter")
  })
})
