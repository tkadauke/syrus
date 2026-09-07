import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("Tailscale admin page reports the unconfigured state when no tailnet is available", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/admin/plugins")
  const pluginCard = page.getByRole("region", { name: "Registered plugins" }).locator("article", { hasText: "Tailscale" })
  await expect(pluginCard).toBeVisible()
  const enableButton = pluginCard.getByRole("button", { name: "Enable" })
  if (await enableButton.isVisible()) {
    await enableButton.click()
    await expect(pluginCard.getByRole("button", { name: "Disable" })).toBeVisible()
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
  await expect(page.getByText("/dev/net/tun present")).toBeVisible()

  // No hostname/ts.net URL to show without a connected daemon, and the
  // "install the mobile app" tip only renders once connected -- neither
  // appears in the unconfigured state.
  await expect(page.getByText("ts.net URL")).toHaveCount(0)
  await expect(page.getByText("Install the Tailscale app", { exact: false })).toHaveCount(0)
})
