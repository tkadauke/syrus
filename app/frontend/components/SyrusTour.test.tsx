import { render } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { SyrusTour } from "./SyrusTour"

const TOKENS: Record<string, string> = {
  "--color-brand": "#b6492e",
  "--color-neutral": "#374151",
  "--color-text-secondary": "#6b7280",
  "--color-on-brand": "#0a0a0a"
}

vi.mock("../lib/colorTokens", () => ({
  useColorTokens: (names: string[]) => names.map((name) => TOKENS[name] ?? "")
}))

type JoyrideStyles = { buttonPrimary?: { color?: string } }

let lastStyles: JoyrideStyles | undefined

vi.mock("react-joyride", () => ({
  Joyride: (props: { styles?: JoyrideStyles }) => {
    lastStyles = props.styles
    return null
  }
}))

describe("SyrusTour", () => {
  it("colors the primary button text from the on-brand token instead of a hardcoded white", () => {
    render(<SyrusTour run steps={[{ target: "body", content: "Step" }]} />)

    expect(lastStyles?.buttonPrimary?.color).toBe(TOKENS["--color-on-brand"])
  })
})
