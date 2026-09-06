import { defineConfig } from "@playwright/test"
import { existsSync, readdirSync } from "node:fs"
import path from "node:path"

// Reuses the Chromium build the worker image already downloads for the
// SyrusBrowser MCP tool set (see Dockerfile's worker-deps stage and
// plugins/browser/app/services/syrus_browser/session.rb) instead of letting
// Playwright fetch its own copy at test time.
const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH ?? "/opt/ms-playwright"

// Core E2E specs live in e2e/; each plugin owns its own under
// plugins/<name>/e2e/. Selecting tests by a path argument is ambiguous here
// (every plugin's path contains "e2e/", so does core's), so each tree gets
// its own named Playwright project instead: `--project=core` or
// `--project=<plugin-name>` picks exactly one, no path collision possible.
// Omitting --project runs every project, i.e. core + all plugins.
const pluginsDir = path.join(__dirname, "plugins")
const pluginProjects = existsSync(pluginsDir)
  ? readdirSync(pluginsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory())
      .filter((entry) => existsSync(path.join(pluginsDir, entry.name, "e2e")))
      .map((entry) => ({
        name: entry.name,
        testDir: path.join(pluginsDir, entry.name, "e2e")
      }))
  : []

export default defineConfig({
  timeout: 30_000,
  webServer: {
    command: "bin/syrus-preview-dev",
    url: "http://127.0.0.1:3000/up",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000
  },
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:3000",
    headless: true,
    launchOptions: {
      executablePath: `${browsersPath}/chromium-1200/chrome-linux64/chrome`
    }
  },
  projects: [{ name: "core", testDir: "./e2e" }, ...pluginProjects]
})
