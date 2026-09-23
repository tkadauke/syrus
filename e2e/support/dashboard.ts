import { type Page } from "@playwright/test"

// Opens the Jobs list showing exactly the Jobs whose title matches, by
// encoding a filter tree into the `q` param the chip bar round-trips through
// the URL (Filters::QueryParam).
//
// A spec that looks for one Job's row needs it to be on the page, and left to
// its own devices the list will not cooperate: it opens in whichever smart
// folder another spec last selected (the preference is stored per user), that
// folder hides Jobs for being closed or approved or somebody else's, the sort
// is likewise remembered, and 25 rows per page decide the rest. Every one of
// those is shared state that another spec can move.
//
// Filtering sidesteps all of it. A `q` present in the URL also suppresses the
// default Inbox folder server-side (App::DashboardPayload#active_smart_folder),
// so what comes back is this filter and nothing else -- one row, wherever the
// dashboard happened to be pointed before.
// "contains", not "is": title is a full-text column and rejects an equality
// operator outright (Filters::Chips::Jobs::Title), which comes back as an
// empty list rather than an error.
export async function openJobsListFilteredByTitle(page: Page, title: string) {
  const tree = { and: [ { field: "title", op: "contains", value: title } ] }
  const q = Buffer.from(JSON.stringify(tree)).toString("base64url")

  await page.goto(`/dashboard/jobs?ownership_scope=team&view=list&q=${q}`)
  await page.getByRole("table").first().waitFor()
}

// The row for a single Job, on a list filtered down to it.
export async function jobsListRow(page: Page, title: string) {
  await openJobsListFilteredByTitle(page, title)

  return page.getByRole("row").filter({ has: page.getByRole("link", { name: title, exact: true }) })
}
