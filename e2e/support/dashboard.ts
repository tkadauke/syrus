import { type Page } from "@playwright/test"
import { execFileSync } from "node:child_process"

// The Jobs list opens filtered by the active smart folder's "Preset" chip,
// which hides closed and approved Jobs; removing it is what makes every
// seeded Job show up regardless of the state a prior action moved it to.
//
// Waiting for the chip rather than sampling matters: it renders a beat after
// the table, so a count() taken when the table appears reads zero and the
// click is skipped, leaving the list filtered. Its absence is fine -- the
// preference persists, so a later spec may find it already removed.
export async function removePresetFilter(page: Page) {
  const button = page.getByRole("button", { name: "Remove Preset filter" })
  try {
    await button.waitFor({ timeout: 10_000 })
  } catch {
    return
  }
  await button.click()
}

// The dashboard's sort is a persisted per-user preference, so whichever spec
// last sorted by Queue decides the order every later spec sees, and a
// just-created fixture Job lands somewhere past the first page of 25 instead
// of at the top. Pin it before looking for a row by title.
export function sortDashboardByNewest(email = "demo@syrus.local") {
  if (process.env.E2E_BASE_URL) return

  execFileSync("bin/rails", ["runner",
    `User.find_by!(email_address: ${JSON.stringify(email)}).update_dashboard_sort!(subject: "job", column: "created_at", direction: "desc")`
  ], { env: process.env, stdio: "inherit" })
}
