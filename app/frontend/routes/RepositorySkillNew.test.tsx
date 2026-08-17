import { describe, it, expect, vi, afterEach } from "vitest"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { jsonResponse } from "../testSupport"
import { RepositorySkillNewRoute } from "./RepositorySkillNew"
import type { RepositorySkillsPayload } from "../api/skills"

const SKILLS_PATH = "/api/v1/app/repositories/1/skills"

function payload(overrides: Partial<RepositorySkillsPayload> = {}): RepositorySkillsPayload {
  return {
    repository: {
      id: 1,
      slug: "acme/widgets",
      repository_path: "/repositories/1",
      default_agent_provider: "claude",
      default_agent_provider_label: "Claude"
    },
    skills: [
      {
        name: "investigate",
        description: "Investigate a question about the codebase.",
        source: "built_in",
        resolved_path: null,
        resolved_class: "Skills::Investigate",
        shadows_built_in: false,
        parameters: [
          { key: "question", type: "string", required: true, label: "Question", options: null, default: null, depends_on: null }
        ]
      },
      {
        name: "deploy",
        description: "Deploy the website.",
        source: "repo_override",
        resolved_path: ".syrus/skills/deploy/SKILL.md",
        resolved_class: null,
        shadows_built_in: false,
        parameters: [
          { key: "environment", type: "select", required: true, label: "Environment", options: [ "staging", "production" ], default: null, depends_on: null },
          { key: "notes", type: "text", required: false, label: "Notes", options: null, default: null, depends_on: null },
          { key: "dry_run", type: "boolean", required: false, label: "Dry run", options: null, default: true, depends_on: null },
          { key: "retries", type: "integer", required: false, label: "Retries", options: null, default: 3, depends_on: null }
        ]
      }
    ],
    configured_agent_providers: [],
    priorities: [ "urgent", "high", "medium", "low" ],
    ...overrides
  }
}

function renderRoute(initialPayload = payload(), fetchImpl?: (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>) {
  vi.spyOn(window, "fetch").mockImplementation(fetchImpl || ((input, init) => {
    const url = String(input)
    if (url === SKILLS_PATH && (!init || init.method === undefined || init.method === "GET")) {
      return Promise.resolve(jsonResponse(initialPayload))
    }
    return Promise.resolve(jsonResponse({ error: { code: "not_found", message: "unhandled" } }, 404))
  }))
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/repositories/1/skills/new"]}>
        <Routes>
          <Route element={<RepositorySkillNewRoute />} path="/repositories/:repositoryId/skills/new" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositorySkillNewRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("lists available skills and defaults to the first one selected", async () => {
    renderRoute()

    expect(await screen.findByText("investigate")).toBeInTheDocument()
    expect(screen.getByText("deploy")).toBeInTheDocument()
    expect((screen.getByRole("radio", { name: /investigate/ }) as HTMLInputElement).checked).toBe(true)
    expect(screen.getByRole("textbox", { name: "Question" })).toBeInTheDocument()
  })

  it("shows repo override provenance details for a repo-local skill", async () => {
    renderRoute()

    expect(await screen.findByText("deploy")).toBeInTheDocument()
    expect(screen.getAllByText("Repo override").length).toBeGreaterThan(0)
    expect(screen.getByText((_, node) => node?.textContent === "Resolved from .syrus/skills/deploy/SKILL.md")).toBeInTheDocument()
  })

  it("flags a repo-local skill that shadows a built-in", async () => {
    renderRoute(payload({
      skills: [
        {
          name: "investigate",
          description: "Repo override of investigate.",
          source: "repo_override",
          resolved_path: ".syrus/skills/investigate/SKILL.md",
          resolved_class: null,
          shadows_built_in: true,
          parameters: []
        }
      ]
    }))

    expect(await screen.findByText("investigate")).toBeInTheDocument()
    expect(screen.getByText("Overrides the built-in skill of the same name.")).toBeInTheDocument()
  })

  it("switches the parameter form when a different skill is selected", async () => {
    renderRoute()

    await screen.findByText("deploy")
    fireEvent.click(screen.getByRole("radio", { name: /deploy/ }))

    expect(await screen.findByRole("combobox", { name: "Environment" })).toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "Notes" })).toBeInTheDocument()
    expect(screen.getByRole("checkbox", { name: "Dry run" })).toBeChecked()
    expect((screen.getByRole("spinbutton", { name: "Retries" }) as HTMLInputElement).value).toBe("3")
    expect(screen.queryByRole("textbox", { name: "Question" })).not.toBeInTheDocument()
  })

  it("submits the selected skill's args and navigates to the created job", async () => {
    let postedBody: unknown
    renderRoute(payload(), (input, init) => {
      const url = String(input)
      if (url === SKILLS_PATH && init?.method === "POST") {
        postedBody = JSON.parse(String(init.body))
        return Promise.resolve(jsonResponse({
          message: "Skill job created.",
          redirect_to: "/jobs/42",
          job: { id: 42, title: "Skill: investigate", state: "queued", skill_name: "investigate", job_path: "/jobs/42" }
        }, 201))
      }
      if (url === SKILLS_PATH) {
        return Promise.resolve(jsonResponse(payload()))
      }
      return Promise.resolve(jsonResponse({ error: { code: "not_found", message: "unhandled" } }, 404))
    })

    await screen.findByText("investigate")

    fireEvent.change(screen.getByRole("textbox", { name: "Question" }), { target: { value: "What does this do?" } })
    fireEvent.click(screen.getByRole("button", { name: "Launch skill" }))

    await waitFor(() => {
      expect(postedBody).toMatchObject({ name: "investigate", args: { question: "What does this do?" } })
    })
  })

  it("surfaces a validation error from the API without navigating", async () => {
    renderRoute(payload(), (input, init) => {
      const url = String(input)
      if (url === SKILLS_PATH && init?.method === "POST") {
        return Promise.resolve(jsonResponse({ error: { code: "validation_failed", message: "question: is required" } }, 422))
      }
      return Promise.resolve(jsonResponse(payload()))
    })

    await screen.findByText("investigate")

    fireEvent.change(screen.getByRole("textbox", { name: "Question" }), { target: { value: "x" } })
    fireEvent.click(screen.getByRole("button", { name: "Launch skill" }))

    expect(await screen.findByText("question: is required")).toBeInTheDocument()
  })

  it("shows an empty state when the repository has no available skills", async () => {
    renderRoute(payload({ skills: [] }))

    expect(await screen.findByText("No skills are available for this repository.")).toBeInTheDocument()
  })
})
