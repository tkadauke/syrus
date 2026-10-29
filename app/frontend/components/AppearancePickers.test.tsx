import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Avatar } from "./Avatar"
import { AvatarPicker } from "./AvatarPicker"
import { ColorPicker } from "./ColorPicker"
import {
  ACCENT_COLORS,
  ACCENT_FAMILIES,
  DEFAULT_AGENT_ORDER,
  THEME_COLORS,
  accentDark,
  accentRamp,
  colorDistance,
  isCloseToTheme,
  luminance,
  mixHex,
  onColor,
  worstCaseDistance
} from "../lib/appearance"

describe("appearance helpers", () => {
  it("loads the six-family, 72-color accent library", () => {
    expect(ACCENT_FAMILIES).toHaveLength(6)
    expect(ACCENT_COLORS).toHaveLength(72)
    expect(new Set(ACCENT_COLORS.map((color) => color.name))).toHaveLength(72)
    expect(DEFAULT_AGENT_ORDER).toEqual(["#0090FF", "#F5A524", "#9B1C31", "#2B3A9E", "#6E56CF", "#C07C5A", "#8E7BA8", "#A16207"])
  })

  it("keeps shared accent and theme names on one hex", () => {
    for (const color of ACCENT_COLORS) {
      const themeHex = THEME_COLORS[color.name as keyof typeof THEME_COLORS]
      if (themeHex) expect(color.hex).toBe(themeHex)
    }
  })

  it("derives contrast colors, ramps, and dark variants", () => {
    expect(mixHex("#FFFFFF", 50, "#000000")).toBe("#808080")
    expect(onColor("#0090FF")).toBe("#141414")
    expect(onColor("#2B3A9E")).toBe("#FFFFFF")
    expect(onColor("#DCD1FA")).toBe("#141414")
    expect(luminance("#000000")).toBe(0)
    expect(Object.keys(accentRamp("#0090FF"))).toHaveLength(9)
    expect(accentRamp("#0090FF").solid).toBe("#0090FF")
    expect(accentDark("#0090FF")).toEqual(
      expect.objectContaining({ tint: expect.stringMatching(/^#[0-9A-F]{6}$/), ink: expect.stringMatching(/^#[0-9A-F]{6}$/) })
    )
  })

  it("measures OKLab similarity consistently", () => {
    expect(colorDistance("#0090FF", "#F5A524")).toBeCloseTo(37.56643284875839, 10)
    expect(colorDistance("#E5484D", "#9B1C31")).toBeCloseTo(17.7733899369609, 10)
    expect(worstCaseDistance("#0090FF", "#0090FF")).toBeCloseTo(0)
    expect(isCloseToTheme("#B6492E", "#B6492E")).toBe(true)
    expect(isCloseToTheme("#0090FF", "#B6492E")).toBe(false)
  })

  it("renders aligned tone rows and a separate Naturals row", () => {
    const onChange = vi.fn()
    render(<ColorPicker ariaLabel="Coworker color" onChange={onChange} value="#b6492e" />)

    expect(screen.getAllByRole("radio")).toHaveLength(72)
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument()
    expect(screen.getAllByText(/^(Pastel|Dusty|Vivid|Electric|Jewel|Naturals)$/).map((node) => node.textContent)).toEqual([
      "Pastel",
      "Dusty",
      "Vivid",
      "Electric",
      "Jewel",
      "Naturals"
    ])
    expect(within(screen.getByText("Pastel").parentElement!).getAllByRole("radio")).toHaveLength(12)
    expect(within(screen.getByText("Naturals").parentElement!).getAllByRole("radio")).toHaveLength(12)
    expect(screen.getByText("Red")).toBeInTheDocument()
    expect(screen.getByText("Pink")).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Terracotta" })).toHaveAttribute("aria-checked", "true")
    fireEvent.click(screen.getByRole("radio", { name: "Azure" }))
    expect(onChange).toHaveBeenCalledWith("#0090FF")
  })

  it("selects bundled avatars", () => {
    const onChange = vi.fn()
    render(<AvatarPicker ariaLabel="Coworker avatar" onChange={onChange} value="orbit" />)
    expect(screen.getByRole("radio", { name: "Orbit" })).toHaveAttribute("aria-checked", "true")
    fireEvent.click(screen.getByRole("radio", { name: "Sprout" }))
    expect(onChange).toHaveBeenCalledWith("sprout")
  })

  it("prefers an uploaded image, then a bundled avatar, then accent initials", () => {
    const { container, rerender } = render(<Avatar accentHex="#0090FF" avatarKey="orbit" avatarUrl="/uploaded.png" name="Ada Lovelace" />)
    expect(container.querySelector("img")).toHaveAttribute("src", "/uploaded.png")
    rerender(<Avatar accentHex="#0090FF" avatarKey="orbit" avatarUrl={null} name="Ada Lovelace" />)
    expect(container.querySelector("img")).toHaveAttribute("src", "/bundled-avatars/orbit.svg")
    rerender(<Avatar accentHex="#0090FF" avatarKey={null} avatarUrl={null} name="Ada Lovelace" />)
    expect(screen.getByText("AL")).toHaveStyle({ backgroundColor: "#0090FF", color: "#141414" })
    expect(screen.getByText("AL").getAttribute("style")).toContain("--agent-tint")
  })
})
