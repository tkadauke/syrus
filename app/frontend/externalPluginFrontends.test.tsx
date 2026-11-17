import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { getPluginContribution, registerPluginContribution } from "./pluginContributionRegistry"
import { loadExternalPluginFrontends } from "./externalPluginFrontends"

const entry = (name: string) => ({
  name,
  bundle_url: `/api/v1/app/plugin_frontends/${name}/bundle?v=hash`,
  css_url: `/api/v1/app/plugin_frontends/${name}/css?v=hash`,
  hash: "hash"
})

describe("external plugin frontend loading", () => {
  it("imports a host-contract bundle and observes its registry contribution", async () => {
    await loadExternalPluginFrontends([entry("fixture_import_map")], async () => {
      registerPluginContribution("workspace_tab", "fixture_import_map", "Example", { default: () => null })
    })

    expect(getPluginContribution("workspace_tab", "fixture_import_map", "Example")).toBeDefined()
    expect(document.querySelector<HTMLLinkElement>('link[data-syrus-plugin-css="fixture_import_map"]')?.href).toContain("/css?v=hash")
  })

  it("logs and skips a throwing bundle so application rendering can continue", async () => {
    const error = new Error("broken external bundle")
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => undefined)

    await expect(loadExternalPluginFrontends([entry("broken_fixture")], async () => Promise.reject(error))).resolves.toBeUndefined()
    render(<main>Application rendered</main>)

    expect(screen.getByText("Application rendered")).toBeInTheDocument()
    expect(consoleError).toHaveBeenCalledWith("[plugin frontend] Failed to load broken_fixture", error)
  })
})
