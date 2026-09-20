import { render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { CodeBlock } from "./CodeBlock"
import * as highlighterLib from "../lib/highlighter"

describe("CodeBlock", () => {
  it("renders Shiki tokens as spans colored with --shiki-token-* custom properties", async () => {
    render(<CodeBlock code={"class User\nend\n"} lang="ruby" />)

    const keyword = await screen.findByText("class")
    expect(keyword.tagName).toBe("SPAN")
    expect(keyword.style.color).toBe("var(--shiki-token-keyword)")
    expect(screen.getByText("User").style.color).toBe("var(--shiki-token-function)")
    expect(keyword.closest("pre")?.textContent).toBe("class User\nend\n")
  })

  it("renders plain, unhighlighted text when there is no recognized language", () => {
    const { container } = render(<CodeBlock code="class User" lang={null} />)

    const code = container.querySelector("code")
    expect(code?.textContent).toBe("class User")
    expect(code?.querySelector("span")).toBeNull()
  })

  it("applies the given className to the wrapping <pre>", () => {
    const { container } = render(<CodeBlock className="my-code" code="x" lang={null} />)

    expect(container.querySelector("pre")).toHaveClass("my-code")
  })

  it("degrades to plain text without an unhandled rejection when the highlighter fails to load (e.g. CSP-blocked WASM)", async () => {
    const tokenizeSpy = vi.spyOn(highlighterLib, "tokenizeLines").mockRejectedValue(new Error("wasm-unsafe-eval blocked"))
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})

    const { container } = render(<CodeBlock code="class User" lang="ruby" />)

    await waitFor(() => expect(tokenizeSpy).toHaveBeenCalled())
    await waitFor(() => expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("Code highlighting failed"), expect.any(Error)))

    const code = container.querySelector("code")
    expect(code?.textContent).toBe("class User")
    expect(code?.querySelector("span")).toBeNull()

    tokenizeSpy.mockRestore()
    warnSpy.mockRestore()
  })
})
