import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import type { AchievementUnlock, AchievementsPayload } from "../api/achievements"
import Achievements from "./Achievements"

function unlock(overrides: Partial<AchievementUnlock>): AchievementUnlock {
  return {
    id: 1,
    key: "example.first_job_landed",
    version: 1,
    scope: "user",
    category: "landing",
    rarity: "common",
    visibility: "visible",
    presentation: { title_key: "achievements:example.first_job_landed.title", description_key: "achievements:example.first_job_landed.description" },
    unlocked_at: "2026-11-24T10:00:00Z",
    acknowledged: true,
    acknowledged_at: "2026-11-24T10:05:00Z",
    evidence_link: null,
    ...overrides
  }
}

const payload: AchievementsPayload = {
  achievements: [
    unlock({ id: 1, evidence_link: { kind: "job", id: 12, slug: "JOB-12" } }),
    unlock({
      id: 2,
      key: "example.first_epic_landed",
      scope: "instance",
      acknowledged: false,
      acknowledged_at: null,
      presentation: { title_key: "achievements:example.first_epic_landed.title" }
    })
  ],
  locked: [
    { hidden: true, scope: "instance" },
    {
      hidden: false,
      key: "example.later",
      scope: "user",
      category: "landing",
      rarity: "common",
      presentation: { title_key: "achievements:example.secret_milestone.title" }
    }
  ]
}

function renderPage(fetchImpl: (url: string, init?: RequestInit) => Response | Promise<Response>) {
  const fetchMock = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => fetchImpl(String(input), init))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/achievements"]}>
        <Achievements />
      </MemoryRouter>
    </QueryClientProvider>
  )
  return fetchMock
}

afterEach(() => vi.restoreAllMocks())

describe("Achievements collection page", () => {
  it("separates instance and personal achievements, with locked and hidden handling and evidence links", async () => {
    renderPage(() => jsonResponse(payload))

    const instance = await screen.findByRole("region", { name: "Instance milestones" })
    const personal = screen.getByRole("region", { name: "Your accomplishments" })
    expect(within(instance).getByText("First Epic landed")).toBeInTheDocument()
    expect(within(instance).getByTestId("achievement-hidden")).toHaveTextContent("Hidden achievement")
    expect(within(instance).queryByText("Secret milestone")).toBeNull()
    expect(within(personal).getByText("First Job landed")).toBeInTheDocument()
    expect(within(personal).getByTestId("achievement-locked")).toHaveTextContent("Locked")
    expect(within(personal).getByRole("link", { name: "Open JOB-12" })).toHaveAttribute("href", "/jobs/12")
    expect(within(instance).queryByRole("link")).toBeNull()
    expect(within(instance).getByText("New")).toBeInTheDocument()
  })

  it("acknowledges an unacknowledged unlock", async () => {
    const fetchMock = renderPage((url, init) => (init?.method === "POST" ? jsonResponse({ achievement: payload.achievements[1] }) : jsonResponse(payload)))

    fireEvent.click(await screen.findByRole("button", { name: "Acknowledge First Epic landed" }))

    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => String(url).endsWith("/achievements/2/acknowledge"))).toBe(true))
  })

  it("replays a reveal through the shared reveal dialog", async () => {
    const fetchMock = renderPage((url, init) => {
      if (init?.method === "POST" && url.endsWith("/replay"))
        return jsonResponse({ achievement: { ...payload.achievements[0], acknowledged: false, acknowledged_at: null } })
      if (init?.method === "POST") return jsonResponse({ achievement: payload.achievements[0] })
      return jsonResponse(payload)
    })

    fireEvent.click(await screen.findByRole("button", { name: "Replay First Job landed" }))

    expect(await screen.findByRole("dialog")).toBeInTheDocument()
    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => String(url).endsWith("/achievements/1/acknowledge"))).toBe(true))
  })

  it("resets the viewer's acknowledgments", async () => {
    const fetchMock = renderPage((url, init) => (init?.method === "POST" ? jsonResponse({ reset: 1 }) : jsonResponse(payload)))

    await screen.findByText("First Epic landed")
    fireEvent.click(screen.getByRole("button", { name: "Replay all reveals" }))

    await waitFor(() => expect(fetchMock.mock.calls.some(([url]) => String(url).endsWith("/achievements/reset_acknowledgments"))).toBe(true))
  })

  it("offers a retry when loading fails", async () => {
    let calls = 0
    renderPage(() => (calls++ === 0 ? jsonResponse({ error: { message: "boom" } }, 500) : jsonResponse(payload)))

    expect(await screen.findByText("Achievements could not be loaded.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    expect(await screen.findByText("First Epic landed")).toBeInTheDocument()
  })
})
