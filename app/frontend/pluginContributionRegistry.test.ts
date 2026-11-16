import { describe, expect, it, vi } from "vitest"
import {
  getPluginContribution,
  getPluginContributions,
  loadPluginContribution,
  registerPluginContribution,
  subscribeToPluginContributions
} from "./pluginContributionRegistry"

describe("plugin contribution registry", () => {
  it("registers eager and lazy contributions and looks them up synchronously", async () => {
    const eager = { default: "eager" }
    const lazy = () => Promise.resolve({ default: "lazy" })

    registerPluginContribution("admin_page", "registry_test", "registry_test/Eager", eager)
    registerPluginContribution("admin_page", "registry_test", "registry_test/Lazy", lazy)

    expect(getPluginContribution("admin_page", "registry_test", "registry_test/Eager")).toBe(eager)
    expect(getPluginContributions("admin_page")).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ pluginName: "registry_test", key: "registry_test/Eager", contribution: eager }),
        expect.objectContaining({ pluginName: "registry_test", key: "registry_test/Lazy", contribution: lazy })
      ])
    )
    await expect(loadPluginContribution(lazy)).resolves.toEqual({ default: "lazy" })
  })

  it("keeps the first registration for a duplicate kind, plugin, and key", () => {
    const first = { default: "first" }
    registerPluginContribution("sidebar_page", "duplicate_test", "duplicate_test/Page", first)
    registerPluginContribution("sidebar_page", "duplicate_test", "duplicate_test/Page", { default: "replacement" })

    expect(getPluginContribution("sidebar_page", "duplicate_test", "duplicate_test/Page")).toBe(first)
  })

  it("returns undefined for missing contributions", () => {
    expect(getPluginContribution("workspace_tab", "missing_test", "missing_test/Nope")).toBeUndefined()
  })

  it("notifies subscribers only when a new contribution is added", () => {
    const listener = vi.fn()
    const unsubscribe = subscribeToPluginContributions(listener)

    registerPluginContribution("workspace_tab", "subscription_test", "subscription_test/Panel", { default: "panel" })
    registerPluginContribution("workspace_tab", "subscription_test", "subscription_test/Panel", { default: "duplicate" })
    expect(listener).toHaveBeenCalledTimes(1)

    unsubscribe()
    registerPluginContribution("workspace_tab", "subscription_test", "subscription_test/Other", { default: "other" })
    expect(listener).toHaveBeenCalledTimes(1)
  })
})
