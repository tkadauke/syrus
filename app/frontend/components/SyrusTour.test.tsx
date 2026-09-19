import { render } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SyrusTour } from "./SyrusTour"

const { joyrideCalls } = vi.hoisted(() => ({
  joyrideCalls: [] as unknown[]
}))

vi.mock("react-joyride", () => ({
  Joyride: (props: unknown) => {
    joyrideCalls.push(props)
    return null
  }
}))

vi.mock("../hooks/useT", () => ({
  useT: () => ({ t: (key: string) => key })
}))

vi.mock("../lib/colorTokens", () => ({
  useColorTokens: (names: string[]) => names.map((name) => {
    if (name === "--color-on-brand") return "rgb(255, 252, 248)"
    return name
  })
}))

describe("SyrusTour", () => {
  afterEach(() => {
    joyrideCalls.length = 0
  })

  it("uses token-derived text color for the Joyride primary button", () => {
    render(<SyrusTour run steps={[{ target: "body", content: "Tour step" }]} />)

    expect(joyrideCalls[0]).toEqual(expect.objectContaining({
      styles: expect.objectContaining({
        buttonPrimary: expect.objectContaining({
          color: "rgb(255, 252, 248)"
        })
      })
    }))
  })
})
