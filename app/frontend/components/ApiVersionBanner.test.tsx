import { act, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { ApiVersionBanner } from "./ApiVersionBanner"
import { announceAppUpdate, resetAppUpdateForTests } from "../lib/appUpdate"

describe("ApiVersionBanner", () => {
  afterEach(() => {
    resetAppUpdateForTests()
    window.sessionStorage.clear()
    vi.unstubAllGlobals()
  })

  it("shows a dismissible notice for a compatible revision without reloading", async () => {
    render(<ApiVersionBanner />)

    act(() => announceAppUpdate("compatible", "revision:new"))

    expect(screen.getByRole("status")).toHaveTextContent("A new version of Syrus is available.")
    expect(screen.getByRole("button", { name: "Reload" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Dismiss notification" })).toBeInTheDocument()
  })

  it("persists a breaking-update prompt and starts one worker update", async () => {
    const getRegistration = vi.fn(() => new Promise<ServiceWorkerRegistration | undefined>(() => {}))
    vi.stubGlobal("navigator", { ...window.navigator, serviceWorker: { getRegistration } })
    render(<ApiVersionBanner />)
    const { checkApiVersion, readApiVersionMismatch } = await import("../api/version")

    await act(async () => {
      checkApiVersion({ v: 2 })
      checkApiVersion({ v: 2 })
      await Promise.resolve()
    })

    expect(screen.getByRole("alert")).toHaveTextContent("Syrus must reload because the API changed")
    expect(screen.getByRole("button", { name: "Reload now" })).toBeInTheDocument()
    expect(readApiVersionMismatch()).toEqual({ actual: 2, expected: 1 })
    expect(getRegistration).toHaveBeenCalledTimes(1)
  })
})
