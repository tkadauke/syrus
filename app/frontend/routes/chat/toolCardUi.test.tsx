import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { Row } from "./toolCardUi"

describe("toolCardUi Row", () => {
  it("stays self-contained for direct CardShell usage", () => {
    render(<Row label="Path" value="plugins/browser/app/frontend/browserToolCard.tsx" />)

    expect(screen.getByText("Path")).toBeInTheDocument()
    expect(screen.getByText("plugins/browser/app/frontend/browserToolCard.tsx")).toBeInTheDocument()
    expect(document.querySelector("dt")).toBeNull()
    expect(document.querySelector("dd")).toBeNull()
  })
})
