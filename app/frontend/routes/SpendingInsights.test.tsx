import { jsonResponse } from "../testSupport"
import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { I18nextProvider } from "react-i18next"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import i18n from "../i18n"
import { SpendingInsightsRoute } from "./SpendingInsights"

function basePayload(overrides: Record<string, unknown> = {}) {
  return {
    scope: { admin: true, user_id: 1, label: "All users" },
    filters: {
      start_date: "2026-04-29",
      end_date: "2026-07-28",
      default_window_days: 90,
      agent_provider: null,
      agent_providers: []
    },
    totals: {
      week_usd: 0,
      month_usd: 0,
      lifetime_usd: 0,
      workflow_lifetime_usd: 0,
      chat_lifetime_usd: 0,
      average_job_30d_usd: 0,
      average_merged_pr_30d_usd: 0
    },
    breakdowns: { epics: [], users: [], repositories: [], trigger_kinds: [] },
    top_runs: [],
    trend: [],
    ...overrides
  }
}

function renderSpending(payload = basePayload()) {
  vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <I18nextProvider i18n={i18n}>
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/insights/spending"]}>
          <SpendingInsightsRoute />
        </MemoryRouter>
      </QueryClientProvider>
    </I18nextProvider>
  )
}

describe("SpendingInsights scope label translation", () => {
  afterEach(async () => {
    await i18n.changeLanguage("en")
  })

  it("shows 'All users' in English for admins", async () => {
    renderSpending()
    expect(await screen.findByText(/All users/)).toBeInTheDocument()
  })

  it("shows 'Alle Benutzer' in German for admins", async () => {
    await i18n.changeLanguage("de")
    renderSpending()
    expect(await screen.findByText(/Alle Benutzer/)).toBeInTheDocument()
  })

  it("shows Latin translation for admins", async () => {
    await i18n.changeLanguage("la")
    renderSpending()
    expect(await screen.findByText(/Omnes utentes/)).toBeInTheDocument()
  })

  it("shows the backend-provided display name for non-admins", async () => {
    renderSpending(basePayload({ scope: { admin: false, user_id: 2, label: "jane@example.com" } }))
    expect(await screen.findByText(/jane@example\.com/)).toBeInTheDocument()
  })

  it("constrains long breakdown labels to the entity column", async () => {
    renderSpending(basePayload({
      breakdowns: {
        epics: [{
          id: 181,
          label: "Improved bug reports: routing, context, attachments, and transcript",
          path: "/epics/181",
          jobs_count: 3,
          total_usd: 42.12,
          average_job_usd: 14.04,
          display_number: "EPIC-181"
        }],
        users: [],
        repositories: [],
        trigger_kinds: []
      }
    }))

    const epicLink = await screen.findByRole("link", { name: "EPIC-181 / Improved bug reports: routing, context, attachments, and transcript" })
    expect(epicLink).toHaveClass("block", "truncate")
    expect(epicLink).toHaveAttribute("title", "EPIC-181 / Improved bug reports: routing, context, attachments, and transcript")
    expect(epicLink.closest("table")).toHaveClass("table-fixed", "w-full")
  })
})
