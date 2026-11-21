import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { lazy, Suspense, useState } from "react"
import { vi } from "vitest"
import { describe, expect, it } from "vitest"

vi.mock("../api/browserErrors", () => ({
  buildBrowserErrorPayload: vi.fn((_error, options) => options),
  recordBrowserError: vi.fn().mockResolvedValue({ id: 1 })
}))

import { recordBrowserError } from "../api/browserErrors"
import { PluginErrorBoundary, PluginRenderBoundary } from "./PluginErrorBoundary"

const Throw = () => {
  throw new Error("broken plugin")
}

describe("PluginErrorBoundary", () => {
  it("isolates render errors and reports the plugin name", async () => {
    render(
      <PluginErrorBoundary pluginName="weather">
        <Throw />
      </PluginErrorBoundary>
    )
    expect(screen.getByRole("alert")).toHaveTextContent("weather")
    await waitFor(() => expect(recordBrowserError).toHaveBeenCalledWith(expect.objectContaining({ boundary: "plugin:weather" })))
  })

  // Regression: a suspending plugin component had no Suspense boundary of its
  // own, so React threw #426 into this error boundary and the plugin showed
  // "could not be displayed" instead of rendering once it loaded.
  it("shows a loading state for a suspending plugin component instead of failing", async () => {
    let resolveChunk: (module: { default: () => JSX.Element }) => void = () => {}
    const Loaded = lazy(() => new Promise<{ default: () => JSX.Element }>((resolve) => { resolveChunk = resolve }))
    render(
      <PluginErrorBoundary pluginName="rails">
        <Loaded />
      </PluginErrorBoundary>
    )

    expect(screen.getByRole("status")).toHaveTextContent("Loading...")
    resolveChunk({ default: () => <p>Schema ERD</p> })

    expect(await screen.findByText("Schema ERD")).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("isolates lazy-load rejections", async () => {
    const Rejected = lazy(() => Promise.reject(new Error("chunk missing")))
    render(
      <PluginErrorBoundary pluginName="weather">
        <Suspense fallback="loading">
          <Rejected />
        </Suspense>
      </PluginErrorBoundary>
    )
    expect(await screen.findByRole("alert")).toHaveTextContent("weather")
  })

  it("offers recovery by reloading the application", () => {
    const reload = vi.fn()
    vi.stubGlobal("location", { ...window.location, reload })
    render(
      <PluginErrorBoundary pluginName="weather">
        <Throw />
      </PluginErrorBoundary>
    )
    fireEvent.click(screen.getByRole("button"))
    expect(reload).toHaveBeenCalled()
    vi.unstubAllGlobals()
  })

  it("preserves rendered plugin state across parent rerenders", () => {
    function StatefulPlugin() {
      const [count, setCount] = useState(0)
      return <button onClick={() => setCount((value) => value + 1)}>Count: {count}</button>
    }

    const view = render(<PluginRenderBoundary pluginName="weather" render={() => <StatefulPlugin />} />)
    fireEvent.click(screen.getByRole("button", { name: "Count: 0" }))
    view.rerender(<PluginRenderBoundary pluginName="weather" render={() => <StatefulPlugin />} />)

    expect(screen.getByRole("button", { name: "Count: 1" })).toBeInTheDocument()
  })
})
