import { act, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ApiVersionBanner } from "./ApiVersionBanner"

describe("ApiVersionBanner", () => {
  afterEach(() => {
    window.sessionStorage.clear()
    vi.unstubAllGlobals()
  })

  it("persists a reload prompt and only starts one automatic reload for a mismatch", async () => {
    const getRegistration = vi.fn(() => new Promise<ServiceWorkerRegistration | undefined>(() => {}))
    vi.stubGlobal("navigator", { ...window.navigator, serviceWorker: { getRegistration } })
    render(<ApiVersionBanner />)
    const { checkApiVersion, readApiVersionMismatch } = await import("../api/version")

    await act(async () => {
      checkApiVersion({ v: 2 })
      checkApiVersion({ v: 2 })
      await Promise.resolve()
    })

    expect(screen.getByRole("alert")).toHaveTextContent("A new version is available — reload")
    expect(screen.getByRole("button", { name: "Reload page" })).toBeInTheDocument()
    expect(readApiVersionMismatch()).toEqual({ actual: 2, expected: 1 })
    expect(getRegistration).toHaveBeenCalledTimes(1)
  })
})
