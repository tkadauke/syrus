import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { NotificationsSettingsRoute } from "./NotificationsSettings"

const payload = { notification_preferences: { job_failed: true, job_implemented: true, pr_comment_addressed: true, pr_merged: true, epic_completed: false, main_inconclusive: true, investigation_escalated: true } }

describe("NotificationsSettingsRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("rolls an optimistic toggle back when saving fails", async () => {
    vi.spyOn(window, "fetch").mockImplementation((_input, init) => init?.method === "PATCH"
      ? Promise.resolve(jsonResponse({ error: { message: "Save failed" } }, 500))
      : Promise.resolve(jsonResponse(payload)))
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })}><MemoryRouter><NotificationsSettingsRoute /></MemoryRouter></QueryClientProvider>)

    const toggle = await screen.findByLabelText("Notify me when a job fails")
    fireEvent.click(toggle)
    await waitFor(() => expect(screen.getByText("Save failed")).toBeInTheDocument())
    expect(toggle).toBeChecked()
  })
})
