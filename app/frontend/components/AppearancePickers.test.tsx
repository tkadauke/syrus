import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Avatar } from "./Avatar"
import { AvatarPicker } from "./AvatarPicker"
import { ColorPicker } from "./ColorPicker"
import { APPEARANCE_COLORS, defaultColorKey, resolveAppearanceColor } from "../lib/appearance"

describe("appearance helpers", () => {
  it("resolves theme variants and deterministic handle defaults", () => {
    expect(APPEARANCE_COLORS).toHaveLength(64)
    expect(resolveAppearanceColor("coral-deep", "light").value).toBe("#e9b7aa")
    expect(resolveAppearanceColor("coral-deep", "dark").value).toBe("#6d2d1d")
    expect(defaultColorKey("Syrus")).toBe("cyan-soft")
    expect(defaultColorKey("Syrus")).toBe(defaultColorKey("syrus"))
  })

  it("renders a fixed grid with no free-form color input", () => {
    const onChange = vi.fn()
    render(<ColorPicker ariaLabel="Coworker color" mode="light" onChange={onChange} value="coral-deep" />)

    expect(screen.getAllByRole("radio")).toHaveLength(64)
    expect(screen.queryByRole("textbox")).not.toBeInTheDocument()
    expect(screen.getByRole("radio", { name: "Coral Deep" })).toHaveAttribute("aria-checked", "true")
    fireEvent.click(screen.getByRole("radio", { name: "Sky Soft" }))
    expect(onChange).toHaveBeenCalledWith("sky-soft")
  })

  it("selects bundled avatars", () => {
    const onChange = vi.fn()
    render(<AvatarPicker ariaLabel="Coworker avatar" onChange={onChange} value="orbit" />)

    expect(screen.getByRole("radio", { name: "Orbit" })).toHaveAttribute("aria-checked", "true")
    fireEvent.click(screen.getByRole("radio", { name: "Sprout" }))
    expect(onChange).toHaveBeenCalledWith("sprout")
  })

  it("prefers an uploaded image, then a bundled avatar, then colored initials", () => {
    const { container, rerender } = render(<Avatar avatarKey="orbit" avatarUrl="/uploaded.png" colorKey="sky-soft" name="Ada Lovelace" />)
    expect(container.querySelector("img")).toHaveAttribute("src", "/uploaded.png")

    rerender(<Avatar avatarKey="orbit" avatarUrl={null} colorKey="sky-soft" name="Ada Lovelace" />)
    expect(container.querySelector("img")).toHaveAttribute("src", "/bundled-avatars/orbit.svg")

    rerender(<Avatar avatarKey={null} avatarUrl={null} colorKey="sky-soft" name="Ada Lovelace" />)
    expect(screen.getByText("AL")).toHaveStyle({ backgroundColor: "#d3e6f3" })
  })
})
