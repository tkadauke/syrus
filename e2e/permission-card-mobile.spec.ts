import { expect, test, type Page } from "@playwright/test"
import { signInAsDemo } from "./support/auth"

// The permission decision card must read as one card with a stable footer and
// no horizontal overflow on a phone. The API is stubbed in the browser so the
// fixture needs no seeded authorization request.
const LONG_SCOPE = "SSH deploy@" + "very-long-hostname-".repeat(8) + "example.test"

const option = (duration: "chat_session" | "permanent") => ({
  kind: duration === "permanent" ? "always_allow_similar" : "allow_chat",
  duration,
  breadth: "resource",
  digest: `digest-${duration}`,
  summary: { allows: ["Syrus may capture a screenshot."], excludes: ["Other operations"] },
  draft: {},
  ceiling: {},
  context: { coworker: "Syrus", operation: "browser.screenshot/capture", repository: null, resource_scope_label: LONG_SCOPE, duration }
})

const permissionRequest = {
  id: 9,
  state: "pending",
  actionable: true,
  purpose: "Capture a screenshot",
  requested_by: "agent",
  runtime_role: null,
  created_at: "2026-11-24T00:00:00Z",
  checkpoint_state: null,
  non_actionable_reason: null,
  origin: null,
  subject: null,
  repository: null,
  presentation: {
    statement: "Allow Syrus to capture a screenshot?",
    agent: "Syrus",
    origin: "Chat",
    scope: LONG_SCOPE,
    consequences: ["read what is on screen"],
    requested_durations: ["This one time"]
  },
  items: [
    {
      id: 33,
      kind: "operation",
      state: "pending",
      capability: "browser.screenshot",
      operation: "browser.screenshot/capture",
      resource_type: "none",
      resource_scope: {},
      arguments: {},
      effects: [],
      risk: null,
      purpose: null,
      policy_chain: [],
      decisive_rule: {},
      requested_durations: ["invocation"],
      selected_duration: null,
      decision_reason: null,
      decided_at: null,
      smart_option: option("chat_session"),
      smart_options: [option("chat_session"), option("permanent")]
    }
  ]
}

async function stubPermissionRequests(page: Page) {
  await page.route("**/api/v1/app/permission_requests**", async (route) => {
    const url = new URL(route.request().url())
    const body = url.pathname.endsWith("/count")
      ? { summary: { pending_count: 1, blocked_agent_count: 0 } }
      : url.pathname.endsWith("/9")
        ? { request: permissionRequest }
        : {
            requests: [permissionRequest],
            summary: { pending_count: 1, blocked_agent_count: 0 },
            pagination: { page: 1, per_page: 50, total: 1, total_pages: 1 }
          }
    await route.fulfill({ contentType: "application/json", body: JSON.stringify(body) })
  })
}

for (const viewport of [
  { name: "narrow phone", width: 320, height: 700 },
  { name: "phone", width: 402, height: 812 }
]) {
  test(`permission card keeps its decision hierarchy without overflow on ${viewport.name}`, async ({ page }) => {
    await page.setViewportSize({ width: viewport.width, height: viewport.height })
    await stubPermissionRequests(page)
    await signInAsDemo(page)
    await page.goto("/permissions/inbox")

    const card = page.getByTestId("permission-request-9")
    await expect(card.getByRole("heading", { name: "Allow Syrus to capture a screenshot?" })).toBeVisible()
    await expect(card.getByText("Technical details")).toBeVisible()
    await expect(card.getByText("browser.screenshot/capture")).toBeHidden()

    const allowOnce = card.getByRole("button", { name: "Allow once" })
    const deny = card.getByRole("button", { name: "Deny" })
    const scope = card.getByLabel("Remember this decision")
    for (const control of [allowOnce, deny, scope]) {
      await expect(control).toBeVisible()
      const box = await control.boundingBox()
      expect(box!.x).toBeGreaterThanOrEqual(0)
      expect(box!.x + box!.width).toBeLessThanOrEqual(viewport.width)
    }
    // Allow once comes first, and the scope control sits below the two buttons.
    const [allowBox, denyBox, scopeBox] = await Promise.all([allowOnce.boundingBox(), deny.boundingBox(), scope.boundingBox()])
    expect(allowBox!.x).toBeLessThan(denyBox!.x)
    expect(scopeBox!.y).toBeGreaterThan(allowBox!.y)

    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)

    await scope.selectOption({ label: "Always allow “capture a screenshot”" })
    const confirm = card.getByRole("button", { name: "Confirm" })
    await expect(confirm).toBeVisible()
    await expect(card.getByText("Settings → Permissions")).toBeVisible()
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true)
  })
}
