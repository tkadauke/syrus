import { describe, expect, it, vi } from "vitest"
import {
  getPluginContribution,
  getPluginContributions,
  registerPluginContribution,
  subscribeToPluginContributions
} from "./pluginContributionRegistry"

describe("plugin contribution registry", () => {
  it("registers and looks up lazy and eager contributions", () => {
    const loader = async () => ({ default: "lazy" })
    const eager = { default: "eager" }

    registerPluginContribution("workspace_tab", "registry_test", "Lazy", loader)
    registerPluginContribution("workspace_tab", "registry_test", "Eager", eager)

    expect(getPluginContribution("workspace_tab", "registry_test", "Lazy")?.value).toBe(loader)
    expect(getPluginContribution("workspace_tab", "registry_test", "Eager")?.value).toBe(eager)
    expect(getPluginContributions("workspace_tab")).toEqual(expect.arrayContaining([
      expect.objectContaining({ pluginName: "registry_test", key: "Lazy" }),
      expect.objectContaining({ pluginName: "registry_test", key: "Eager" })
    ]))
  })

  it("keeps the first registration for a duplicate key", () => {
    registerPluginContribution("admin_page", "registry_test", "Duplicate", { value: "first" })
    registerPluginContribution("admin_page", "registry_test", "Duplicate", { value: "second" })

    expect(getPluginContribution<{ value: string }>("admin_page", "registry_test", "Duplicate")?.value).toEqual({ value: "first" })
  })

  it("returns undefined for a missing contribution", () => {
    expect(getPluginContribution("sidebar_page", "registry_test", "Missing")).toBeUndefined()
  })

  it("notifies subscribers once for a new registration and supports unsubscribing", () => {
    const listener = vi.fn()
    const unsubscribe = subscribeToPluginContributions(listener)

    registerPluginContribution("sidebar_page", "registry_test", "Subscribed", { default: "component" })
    registerPluginContribution("sidebar_page", "registry_test", "Subscribed", { default: "replacement" })

    expect(listener).toHaveBeenCalledOnce()
    expect(listener).toHaveBeenCalledWith({ kind: "sidebar_page", pluginName: "registry_test", key: "Subscribed" })

    unsubscribe()
    registerPluginContribution("sidebar_page", "registry_test", "AfterUnsubscribe", { default: "component" })
    expect(listener).toHaveBeenCalledOnce()
  })
})
