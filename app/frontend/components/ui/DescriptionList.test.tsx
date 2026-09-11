import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { DescriptionList, LinkText, Text } from "@app/components/ui"
import { MemoryRouter } from "react-router-dom"

describe("DescriptionList", () => {
  it("renders metadata with semantic description list elements", () => {
    render(
      <MemoryRouter>
        <DescriptionList.Root aria-label="Repository metadata">
          <DescriptionList.Item label="Repository">
            <LinkText to="/repositories/1">tkadauke/syrus</LinkText>
          </DescriptionList.Item>
          <DescriptionList.Item label="Base branch">
            <Text as="span" variant="mono">main</Text>
          </DescriptionList.Item>
        </DescriptionList.Root>
      </MemoryRouter>
    )

    expect(screen.getByText("Repository").tagName).toBe("DT")
    expect(screen.getByText("tkadauke/syrus").closest("dd")?.parentElement?.tagName).toBe("DIV")
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/1")
    expect(screen.getByText("main").className).toContain("font-mono")
  })

  it("supports compact density and passthrough class escapes", () => {
    render(
      <DescriptionList.Root className="custom-list" data-testid="metadata" density="compact">
        <DescriptionList.Item descriptionClassName="custom-description" label="State" termClassName="custom-term">
          Running
        </DescriptionList.Item>
      </DescriptionList.Root>
    )

    expect(screen.getByTestId("metadata").className).toContain("gap-y-1.5")
    expect(screen.getByTestId("metadata").className).toContain("custom-list")
    expect(screen.getByText("State").className).toContain("custom-term")
    expect(screen.getByText("Running").className).toContain("custom-description")
  })
})
