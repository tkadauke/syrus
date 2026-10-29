import { fireEvent, render, screen } from "@testing-library/react"
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
  accentVariant,
  colorDistance,
  defaultAccentSelection,
  isCloseToTheme,
  luminance,
  mixHex,
  onColor,
  resolveAccentSelection,
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

  it("selects tones, hues, Naturals, and fine-tune variants", () => {
    const onChange = vi.fn()
    const irisLight = accentVariant("#6E56CF", 1)
    render(
      <ColorPicker
        accentRef={{ family: "vivid", index: 9, shade: 1 }}
        ariaLabel="Coworker color"
        name="Atlas"
        initial="A"
        onChange={onChange}
        value={irisLight}
      />
    )

    expect(screen.getByText(`Iris +1 · ${irisLight}`)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Vivid" })).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: "Iris" })).toHaveAttribute("aria-pressed", "true")
    for (const label of ["Pastel", "Dusty", "Vivid", "Electric", "Jewel"]) {
      expect(screen.getByRole("button", { name: label }).lastElementChild).not.toHaveClass("truncate")
      expect(screen.getByRole("button", { name: label })).toHaveTextContent(label)
    }
    expect(screen.getByRole("button", { name: "+1 Light" })).toHaveStyle({ color: onColor(irisLight) })
    expect(screen.getByText("Ready when you are.")).toHaveStyle({ backgroundColor: irisLight, color: onColor(irisLight) })
    expect(screen.getByText("A")).toBeInTheDocument()
    expect(screen.getByText("@Atlas")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Dusty" }))
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#8E7BA8", 1), accentRef: { family: "dusty", index: 9, shade: 1 } })
    fireEvent.click(screen.getByRole("button", { name: "Denim" }))
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#5D7FA8", 1), accentRef: { family: "dusty", index: 7, shade: 1 } })
    fireEvent.click(screen.getByRole("button", { name: "Terracotta" }))
    expect(screen.getByRole("button", { name: "Dusty" })).toHaveAttribute("aria-pressed", "false")
    expect(screen.getByRole("button", { name: "Rosewood" })).toHaveAttribute("aria-pressed", "false")
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#b6492e", 1), accentRef: { family: "earth", index: 0, shade: 1 } })

    fireEvent.click(screen.getByRole("button", { name: "Vivid" }))
    expect(screen.getByRole("button", { name: "Terracotta" })).toHaveAttribute("aria-pressed", "false")
    expect(screen.getByRole("button", { name: "Vivid" })).toHaveAttribute("aria-pressed", "true")
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#E5484D", 1), accentRef: { family: "vivid", index: 0, shade: 1 } })

    fireEvent.click(screen.getByRole("button", { name: "Terracotta" }))
    fireEvent.click(screen.getByRole("button", { name: "Azure" }))
    expect(screen.getByRole("button", { name: "Terracotta" })).toHaveAttribute("aria-pressed", "false")
    expect(screen.getByRole("button", { name: "Vivid" })).toHaveAttribute("aria-pressed", "true")
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#0090FF", 1), accentRef: { family: "vivid", index: 7, shade: 1 } })

    fireEvent.click(screen.getByRole("button", { name: "0 Base" }))
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: "#0090FF", accentRef: { family: "vivid", index: 7, shade: 0 } })
  })

  it("uses a readable on-color label for every fine-tune variant", () => {
    render(<ColorPicker accentRef={{ family: "vivid", index: 9, shade: 0 }} onChange={vi.fn()} value="#6E56CF" />)

    const variants = [
      { shade: -2 as const, label: "−2 Deeper" },
      { shade: -1 as const, label: "−1 Deep" },
      { shade: 0 as const, label: "0 Base" },
      { shade: 1 as const, label: "+1 Light" },
      { shade: 2 as const, label: "+2 Lighter" }
    ]
    for (const variant of variants) {
      const hex = accentVariant("#6E56CF", variant.shade)
      expect(screen.getByRole("button", { name: variant.label })).toHaveStyle({ backgroundColor: hex, color: onColor(hex) })
    }
  })

  it("reopens from a valid reference and falls back to the nearest base color", () => {
    const irisLight = accentVariant("#6E56CF", 1)
    expect(resolveAccentSelection(irisLight, { family: "vivid", index: 9, shade: 1 })).toEqual({
      accentHex: irisLight,
      accentRef: { family: "vivid", index: 9, shade: 1 }
    })
    expect(resolveAccentSelection("#6F57CE", { family: "earth", index: 0, shade: 2 })).toEqual({
      accentHex: "#6E56CF",
      accentRef: { family: "vivid", index: 9, shade: 0 }
    })
  })

  it("uses the first unused color in the default order", () => {
    expect(defaultAccentSelection(["#0090ff", "#F5A524"]).accentHex).toBe("#9B1C31")
  })

  it("uses roving tabindex and arrow keys within swatch rows", () => {
    const onChange = vi.fn()
    render(<ColorPicker accentRef={{ family: "vivid", index: 0, shade: 0 }} onChange={onChange} value="#E5484D" />)
    const poppy = screen.getByRole("button", { name: "Poppy" })
    const tangerine = screen.getByRole("button", { name: "Tangerine" })
    expect(poppy).toHaveAttribute("tabindex", "0")
    expect(tangerine).toHaveAttribute("tabindex", "-1")
    poppy.focus()
    fireEvent.keyDown(poppy, { key: "ArrowRight" })
    expect(tangerine).toHaveFocus()
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: "#F2711C", accentRef: { family: "vivid", index: 1, shade: 0 } })

    const vivid = screen.getByRole("button", { name: "Vivid" })
    vivid.focus()
    fireEvent.keyDown(vivid, { key: "ArrowRight" })
    expect(screen.getByRole("button", { name: "Electric" })).toHaveFocus()
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: "#FF6A00", accentRef: { family: "electric", index: 1, shade: 0 } })

    const base = screen.getByRole("button", { name: "0 Base" })
    base.focus()
    fireEvent.keyDown(base, { key: "ArrowRight" })
    expect(screen.getByRole("button", { name: "+1 Light" })).toHaveFocus()
    expect(onChange).toHaveBeenLastCalledWith({ accentHex: accentVariant("#FF6A00", 1), accentRef: { family: "electric", index: 1, shade: 1 } })
  })

  it("renders in explicit light and dark preview modes", () => {
    const { container, rerender } = render(<ColorPicker mode="light" onChange={vi.fn()} value="#0090FF" />)
    expect(container.querySelector("section")).not.toHaveClass("dark")
    rerender(<ColorPicker mode="dark" onChange={vi.fn()} value="#0090FF" />)
    expect(container.querySelector("section")).toHaveClass("dark")
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
