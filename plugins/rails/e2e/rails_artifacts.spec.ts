import { test, expect } from "@playwright/test"
import { signInAsDemo } from "../../../e2e/support/auth"

test("signed-in user views the ERD and migration diff renderers on a Job's Review tab", async ({ page }) => {
  await signInAsDemo(page)

  await page.goto("/repositories")
  await page.getByRole("link", { name: "demo/syrus-preview" }).click()

  const recentJobs = page.locator("section").filter({ has: page.getByRole("heading", { name: "Recent jobs" }) })
  await recentJobs.getByRole("link", { name: "Inspect preview dashboard states" }).click()

  await expect(page.getByRole("heading", { level: 1 })).toContainText("Inspect preview dashboard states")

  await page.getByRole("button", { name: "Review", exact: true }).click()
  await page.getByRole("button", { name: "Show", exact: true }).click()

  // rails_schema_erd, rendered by SyrusRails::SchemaErdRenderer as one box
  // per table with its columns, foreign keys, and indexes.
  await expect(page.getByText("Schema ERD", { exact: true })).toBeVisible()
  await expect(page.getByText("rails_schema_erd", { exact: true })).toBeVisible()
  await expect(page.getByText("users", { exact: true }).first()).toBeVisible()
  await expect(page.getByText("accounts", { exact: true }).first()).toBeVisible()
  await expect(page.getByText("accounts.id")).toBeVisible()
  await expect(page.getByText("unique idx: email")).toBeVisible()

  // rails_migration_diff, rendered by SyrusRails::MigrationDiffRenderer as a
  // before/after column table plus a change summary list.
  await expect(page.getByText("Migration: AddNeedsAttentionCountToUsers", { exact: true })).toBeVisible()
  await expect(page.getByText("rails_migration_diff", { exact: true })).toBeVisible()
  await expect(page.getByText("AddNeedsAttentionCountToUsers", { exact: true }).first()).toBeVisible()
  await expect(page.getByText("added", { exact: true }).first()).toBeVisible()
  await expect(page.getByText("needs_attention_count", { exact: true }).first()).toBeVisible()
})
