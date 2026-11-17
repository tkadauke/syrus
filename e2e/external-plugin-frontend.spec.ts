import { expect, test } from "@playwright/test"
import { execFileSync } from "node:child_process"
import { cpSync, mkdtempSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { signInAsDemo } from "./support/auth"

let fixtureRoot: string
let fixtureBundle: string

test.beforeAll(() => {
  fixtureRoot = mkdtempSync(join(tmpdir(), "syrus-external-plugin-e2e-"))
  cpSync("spec/fixtures/relocatable_plugin", fixtureRoot, { recursive: true })
  execFileSync("bin/build-plugin-frontend", [fixtureRoot], { cwd: process.cwd(), stdio: "pipe" })
  fixtureBundle = readFileSync(join(fixtureRoot, "dist/frontend/plugin.js"), "utf8")
})

test.afterAll(() => {
  rmSync(fixtureRoot, { recursive: true, force: true })
})

test("loads a built external plugin through the host import map", async ({ page }) => {
  await signInAsDemo(page)

  await page.route("**/__e2e_external_plugin.js", (route) => route.fulfill({ body: fixtureBundle, contentType: "text/javascript" }))
  await page.route("**/__e2e_plugin_registry_probe.js", (route) =>
    route.fulfill({
      body: `
        import { getPluginContribution } from "@syrus/plugin-sdk"
        window.__externalPluginRegistered = Boolean(
          getPluginContribution("workspace_tab", "relocatable_plugin", "Relocatable")
        )
      `,
      contentType: "text/javascript"
    })
  )

  await page.evaluate(async () => {
    const pluginUrl = "/__e2e_external_plugin.js"
    const probeUrl = "/__e2e_plugin_registry_probe.js"
    await import(pluginUrl)
    await import(probeUrl)
  })

  await expect.poll(() => page.evaluate(() => (window as Window & { __externalPluginRegistered?: boolean }).__externalPluginRegistered)).toBe(true)
})
