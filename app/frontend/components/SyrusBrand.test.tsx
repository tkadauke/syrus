import { render, screen, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SyrusBrand } from "./SyrusBrand"

const stableUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5 SyrusDesktopBuild/0.1.5 Safari/537.36"
const testUa = "Mozilla/5.0 Chrome/130.0.0.0 Electron/39.8.10 SyrusDesktop/0.1.5-test.3 SyrusDesktopBuild/0.1.5-test.3 SyrusDesktopChannel/test Safari/537.36"

describe("SyrusBrand", () => {
  afterEach(() => vi.restoreAllMocks())

  it("keeps the stable-channel brand name unchanged without a channel marker", () => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(stableUa)
    const { container } = render(<SyrusBrand />)

    expect(container).toHaveTextContent("Syrus")
    expect(container).not.toHaveTextContent("Syrus Test")
    expect(screen.queryByTestId("test-channel-dot")).toBeNull()
  })

  it.each([false, true])("keeps the test-channel brand named Syrus with one marker when markOnly=%s", (markOnly) => {
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue(testUa)
    const { container } = render(<SyrusBrand markOnly={markOnly} />)

    expect(container).toHaveTextContent("Syrus")
    expect(container).not.toHaveTextContent("Syrus Test")
    expect(within(container).getAllByTestId("test-channel-dot")).toHaveLength(1)
    expect(within(container).getByLabelText(/test build, isolated from your production Syrus/i)).toHaveAttribute(
      "title",
      "This is a side-by-side test build, isolated from your production Syrus."
    )
  })
})
