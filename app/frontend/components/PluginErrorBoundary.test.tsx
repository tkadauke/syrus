import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { lazy, Suspense } from "react"
import { vi } from "vitest"
import { describe, expect, it } from "vitest"

vi.mock("../api/browserErrors", () => ({
  buildBrowserErrorPayload: vi.fn((_error, options) => options),
  recordBrowserError: vi.fn().mockResolvedValue({ id: 1 })
}))

import { recordBrowserError } from "../api/browserErrors"
import { PluginErrorBoundary } from "./PluginErrorBoundary"

const Throw = () => { throw new Error("broken plugin") }

describe("PluginErrorBoundary", () => {
  it("isolates render errors and reports the plugin name", async () => {
    render(<PluginErrorBoundary pluginName="weather"><Throw /></PluginErrorBoundary>)
    expect(screen.getByRole("alert")).toHaveTextContent("weather")
    await waitFor(() => expect(recordBrowserError).toHaveBeenCalledWith(expect.objectContaining({ boundary: "plugin:weather" })))
  })

  it("isolates lazy-load rejections", async () => {
    const Rejected = lazy(() => Promise.reject(new Error("chunk missing")))
    render(<PluginErrorBoundary pluginName="weather"><Suspense fallback="loading"><Rejected /></Suspense></PluginErrorBoundary>)
    expect(await screen.findByRole("alert")).toHaveTextContent("weather")
  })

  it("offers recovery by reloading the application", () => {
    const reload = vi.fn()
    vi.stubGlobal("location", { ...window.location, reload })
    render(<PluginErrorBoundary pluginName="weather"><Throw /></PluginErrorBoundary>)
    fireEvent.click(screen.getByRole("button"))
    expect(reload).toHaveBeenCalled()
    vi.unstubAllGlobals()
  })
})
