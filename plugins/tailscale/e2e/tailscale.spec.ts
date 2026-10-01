import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

// Enabling a plugin reloads the page, and a cold dev-mode re-render can take
// most of a minute -- which is why the post-enable assertion below asks for 60s.
// That request was unreachable without this: the default *test* budget is 30s,
// so the test was killed at 30s no matter what timeout the assertion carried.
// Only CI ever saw it, because the plugin is already enabled on a developer's
// instance and the whole enable branch is skipped.
test.slow()

test("Tailscale admin page reports the unconfigured state when no tailnet is available", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/admin/plugins")
  // By heading, not by any text in the card: a plugin's card lists the
  // plugins that depend on it ("Required by: tailscale, git_mirror"), so a
  // loose text match now resolves to two cards.
  const pluginCard = page.getByRole("region", { name: "Registered plugins" })
    .locator("article")
    .filter({ has: page.getByRole("heading", { name: "Tailscale", exact: true }) })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await page.waitForLoadState("load")
    // Enabling navigates to the plugin's own page (/admin/plugins/<name>); it
    // does not reload the list. So the card locator above cannot resolve any
    // more -- assert on the page we actually land on. `pluginCard` is not used
    // past this block.
    await expect(page.getByRole("button", { name: "Disable" }).first()).toBeVisible({ timeout: 60_000 })
  }

  // No real tailscaled daemon and no TS_AUTHKEY are available in this dev
  // sandbox, so the real (unmocked) backend genuinely reports the
  // unconfigured state -- there's no external network to fake here, unlike
  // the MySQL/K8s sibling plugins.
  await page.goto("/admin/tailscale")
  await expect(page.getByRole("heading", { name: "Tailscale", exact: true })).toBeVisible()
  await expect(page.getByText("Not Configured")).toBeVisible()

  await expect(page.getByText("Auth key set")).toBeVisible()
  await expect(page.getByText("Daemon running")).toBeVisible()

  // No hostname/ts.net URL to show without a connected daemon, and the
  // "install the mobile app" tip only renders once connected -- neither
  // appears in the unconfigured state.
  await expect(page.getByText("ts.net URL")).toHaveCount(0)
  await expect(page.getByText("Install the Tailscale app", { exact: false })).toHaveCount(0)
})
