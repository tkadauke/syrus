import { afterEach, describe, expect, it, vi } from "vitest"

const bootstrap = {
  current_user: { locale: "de" },
  app: {
    external_plugin_frontends: [
      {
        name: "external_fixture",
        bundle_url: "/bundle.js",
        hash: "hash",
        locales: [
          { locale: "en", namespace: "external_fixture", url: "/locales/en.json" },
          { locale: "de", namespace: "external_fixture", url: "/locales/de.json" }
        ]
      }
    ]
  }
}

vi.mock("../api/bootstrap", () => ({ readInitialBootstrap: () => bootstrap }))

describe("external plugin locales", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("loads and uses the active locale", async () => {
    vi.resetModules()
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async (url: string) =>
          new Response(JSON.stringify({ greeting: url.endsWith("de.json") ? "Hallo" : "Hello" }), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
      )
    )
    const { default: i18n, loadPluginLocales } = await import("./index")
    await loadPluginLocales("external_fixture")
    expect(i18n.t("greeting", { ns: "external_fixture" })).toBe("Hallo")
  })

  it("falls back to English when the active locale cannot be loaded", async () => {
    vi.resetModules()
    vi.stubGlobal(
      "fetch",
      vi.fn(async (url: string) =>
        url.endsWith("de.json")
          ? new Response("missing", { status: 404 })
          : new Response(JSON.stringify({ greeting: "Hello" }), { status: 200, headers: { "Content-Type": "application/json" } })
      )
    )
    const { default: i18n, loadPluginLocales } = await import("./index")
    await loadPluginLocales("external_fixture")
    expect(i18n.t("greeting", { ns: "external_fixture" })).toBe("Hello")
  })
})
