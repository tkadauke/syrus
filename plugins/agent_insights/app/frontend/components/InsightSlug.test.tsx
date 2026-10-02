import { render, screen } from "@testing-library/react"
import type { ReactNode } from "react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { setSlugReferenceRegistryForTests, type SlugReferenceRegistryEntry } from "@app/lib/slugReferenceRegistry"
import { InsightSlug } from "./InsightSlug"

vi.mock("@app/components/SlugHoverCard", () => ({
  SlugReferenceCard: ({ entry, id, children }: { entry: SlugReferenceRegistryEntry; id: number; children: ReactNode }) => (
    <span data-id={id} data-prefix={entry.prefix} data-testid="slug-reference-card">
      {children}
    </span>
  )
}))

const entry = (): SlugReferenceRegistryEntry => ({
  prefix: "INSIGHT",
  type: "insight",
  displayLabel: "Insight",
  copyable: true,
  linkable: true,
  previewAvailable: true,
  linkifiesGeneratedText: true,
  hrefTemplate: "/s/INSIGHT-:id",
  mobileInteractionHints: { tap: "open", long_press: "copy" },
  pluginPreviewComponent: null
})

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("InsightSlug", () => {
  it("wraps INSIGHT refs with the shared slug reference card", () => {
    setSlugReferenceRegistryForTests([entry()])

    render(<InsightSlug slug="INSIGHT-42" />)

    expect(screen.getByTestId("slug-reference-card")).toHaveAttribute("data-prefix", "INSIGHT")
    expect(screen.getByTestId("slug-reference-card")).toHaveAttribute("data-id", "42")
    expect(screen.getByRole("button", { name: "Copy INSIGHT-42 to clipboard" })).toBeInTheDocument()
  })
})
