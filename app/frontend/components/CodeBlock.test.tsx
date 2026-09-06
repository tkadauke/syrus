import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { CodeBlock } from "./CodeBlock"

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
})
