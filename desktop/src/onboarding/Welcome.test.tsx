import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { Welcome } from "./Welcome"

function stubPlatform(platform: string) {
  ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = { platform }
}

describe("Welcome", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("offers the local install on macOS", () => {
    stubPlatform("darwin")
    const onChoose = vi.fn()
    render(<Welcome onChoose={onChoose} />)

    fireEvent.click(screen.getByRole("button", { name: /Install on this Mac/ }))
    expect(onChoose).toHaveBeenCalledWith("local")
  })

})
