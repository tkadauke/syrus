import { defineConfig } from "@playwright/test"
import { existsSync, readdirSync } from "node:fs"
import path from "node:path"

// Reuses the Chromium build the worker image already downloads for the
// SyrusBrowser MCP tool set (see Dockerfile's worker-deps stage and
// plugins/browser/app/services/syrus_browser/session.rb) instead of letting
// Playwright fetch its own copy at test time.
//
// That reuse is an optimisation for the image, not a requirement: both the path
// and the `chrome-linux64/chrome` layout under it are Linux-specific, so on a
// developer's machine there is nothing there. Pinning it unconditionally made
// every local run die with "Failed to launch chromium because executable
// doesn't exist at /opt/ms-playwright/...". When the pinned binary is absent we
// fall through to the browser Playwright manages itself.
const browsersPath = process.env.PLAYWRIGHT_BROWSERS_PATH ?? "/opt/ms-playwright"
const pinnedChromium = path.join(browsersPath, "chromium-1200", "chrome-linux64", "chrome")
const launchOptions = existsSync(pinnedChromium) ? { executablePath: pinnedChromium } : {}

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

// A port of its own, not 3000. `reuseExistingServer` adopts whatever is already
// listening, and on a developer's machine 3000 is routinely taken by something
// that is not this suite's server -- `bin/dev`, or a Colima/Docker forward for
// the local Syrus stack, which answers /up convincingly. The suite would then
// run against that instance instead, and job-creation.spec.ts would create a
// real Job in someone else's database. Override with E2E_PORT if 3101 is taken.
const port = Number(process.env.E2E_PORT ?? 3101)
const baseURL = process.env.E2E_BASE_URL ?? `http://127.0.0.1:${port}`

export default defineConfig({
  timeout: 30_000,
  // Skipped entirely when E2E_BASE_URL points the suite at an already-running
  // server, which is how CI targets a deployed instance.
  webServer: process.env.E2E_BASE_URL ? undefined : {
    command: `PORT=${port} bin/syrus-preview-dev`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: !process.env.CI,
    // bin/syrus-preview-dev builds the SPA and Tailwind before it starts Rails,
    // and a cold local boot of this app -- every plugin, development mode --
    // does not finish inside the two minutes that were enough for a warm image.
    timeout: 420_000
  },
  use: {
    baseURL,
    headless: true,
    launchOptions
  },
  projects: [{ name: "core", testDir: "./e2e" }, ...pluginProjects]
})
