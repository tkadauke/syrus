import { render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import type { ReactNode } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { ProfileRoute } from "./Profile"
import { TeamDirectoryRoute, TeamProfileRoute } from "./Profiles"

describe("profile routes", () => {
  it("renders the team directory without leaking private profile data", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        team_user_count: 2,
        profiles: [
          {
            id: 7,
            display_name: "Ada Lovelace",
            first_name: "Ada",
            last_name: "Lovelace",
            github_handle: "ada",
            role_label: "Operator",
            avatar_url: null,
            bio_excerpt: "Keeps analytical engines from lying.",
            counts: { repositories: 1, epics: 2, jobs: 3, open_jobs: 1 },
            profile_path: "/profiles/7"
          }
        ]
      })
    )

    renderRoute(<TeamDirectoryRoute />, "/app-shell/profiles")

    expect(await screen.findByRole("main", { name: "Team directory" })).toBeInTheDocument()
    const profileLink = await screen.findByRole("link", { name: "Ada Lovelace" })
    expect(profileLink).toHaveAttribute("href", "/app-shell/profiles/7")
    expect(screen.getByText("Keeps analytical engines from lying.")).toBeInTheDocument()
    expect(screen.getByText("@ada")).toBeInTheDocument()
    expect(screen.queryByText("ada@example.com")).not.toBeInTheDocument()
    expect(screen.queryByText("ghp_profile_secret")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/profiles", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("suppresses directory cards when this is a single-user instance", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        team_user_count: 1,
        profiles: [
          {
            id: 1,
            display_name: "Solo Operator",
            first_name: null,
            last_name: null,
            github_handle: null,
            role_label: "Admin",
            avatar_url: null,
            bio_excerpt: "Private installation.",
            counts: { repositories: 0, epics: 0, jobs: 0, open_jobs: 0 },
            profile_path: "/profiles/1"
          }
        ]
      })
    )

    renderRoute(<TeamDirectoryRoute />, "/profiles")

    expect(await screen.findByText("Only one user exists on this Syrus instance.")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Solo Operator" })).not.toBeInTheDocument()
    expect(screen.queryByText("Private installation.")).not.toBeInTheDocument()
  })

  it("renders a team profile with public fields, work summaries, and prefixed links", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(teamProfilePayload()))

    renderRoute(
      <Routes>
        <Route element={<TeamProfileRoute />} path="/app-shell/profiles/:id" />
      </Routes>,
      "/app-shell/profiles/7"
    )

    expect(await screen.findByRole("main", { name: "Team profile" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Ada Lovelace" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "@ada" })).toHaveAttribute("href", "https://github.com/ada")
    expect(screen.getByText("Mathematician and operator.")).toBeInTheDocument()

    const epics = screen.getByRole("heading", { name: "Owned epics" }).closest("section")
    expect(within(epics as HTMLElement).getByRole("link", { name: "Profile coverage" })).toHaveAttribute("href", "/app-shell/epics/12")
    const jobs = screen.getByRole("heading", { name: "Owned jobs" }).closest("section")
    expect(within(jobs as HTMLElement).getByRole("link", { name: "Ship profile page" })).toHaveAttribute("href", "/app-shell/jobs/55")
    const repositories = screen.getByRole("heading", { name: "Repositories" }).closest("section")
    expect(within(repositories as HTMLElement).getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(screen.queryByText("ada@example.com")).not.toBeInTheDocument()
    expect(screen.queryByText("sk-profile-secret")).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/profiles/7", expect.objectContaining({ credentials: "same-origin" }))
  })

  it("renders the single-user profile page details and empty states", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(teamProfilePayload({
      profile_bio: null,
      profile_company: null,
      profile_location: null,
      profile_website: null,
      counts: { repositories: 0, epics: 0, jobs: 0, open_jobs: 0 },
      jobs: []
    })))

    renderRoute(
      <Routes>
        <Route element={<ProfileRoute />} path="/app-shell/profiles/:id" />
      </Routes>,
      "/app-shell/profiles/7"
    )

    expect(await screen.findByRole("main", { name: "User profile" })).toBeInTheDocument()
    expect(await screen.findByRole("heading", { name: "Ada Lovelace" })).toBeInTheDocument()
    expect(screen.getByText("No bio listed.")).toBeInTheDocument()
    expect(screen.getByText("No company listed")).toBeInTheDocument()
    expect(screen.getByText("No location listed")).toBeInTheDocument()
    expect(screen.getByText("No website listed")).toBeInTheDocument()
    expect(screen.getByText("No owned work yet. Jobs, epics, and repository activity will appear here once this user starts delegating work.")).toBeInTheDocument()
  })
})

function renderRoute(children: ReactNode, path: string) {
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[path]}>
        {children}
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } })
}

function teamProfilePayload(overrides: Record<string, unknown> = {}) {
  return {
    team_user_count: 2,
    profile: {
      id: 7,
      display_name: "Ada Lovelace",
      first_name: "Ada",
      last_name: "Lovelace",
      github_handle: "ada",
      role_label: "Operator",
      profile_bio: "Mathematician and operator.",
      profile_location: "London",
      profile_company: "Analytical Engines Ltd",
      profile_website: "https://example.com/ada",
      avatar_url: null,
      profile_path: "/profiles/7",
      counts: { repositories: 1, epics: 1, jobs: 1, open_jobs: 1 },
      repositories: [
        { id: 3, slug: "acme/widgets", path: "/repositories/3" }
      ],
      epics: [
        {
          id: 12,
          display_number: "#12",
          title: "Profile coverage",
          state: "open",
          repository: { id: 3, slug: "acme/widgets", path: "/repositories/3" },
          updated_at: "2026-05-30T12:00:00Z",
          path: "/epics/12"
        }
      ],
      jobs: [
        {
          id: 55,
          title: "Ship profile page",
          state: "running",
          kind: "issue",
          repository: { id: 3, slug: "acme/widgets", path: "/repositories/3" },
          updated_at: "2026-05-30T12:00:00Z",
          path: "/jobs/55"
        }
      ],
      recent_activity: [
        {
          type: "job",
          title: "Ship profile page",
          state: "running",
          repository_slug: "acme/widgets",
          occurred_at: "2026-05-30T12:00:00Z",
          path: "/jobs/55"
        }
      ],
      ...overrides
    }
  }
}
