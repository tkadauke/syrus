import { jsonResponse } from "../../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { resetBackendUpdateStoreForTests, useBackendOutage } from "../../hooks/useBackendUpdate"
import { GithubTokenStep } from "./GithubTokenStep"

function renderStep(props: { onSaved?: () => void; saveLabel?: string } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <GithubTokenStep onSaved={props.onSaved ?? (() => {})} saveLabel={props.saveLabel} />
    </QueryClientProvider>
  )
}

// Route fetch by the path the api client hits.
function mockRoutes(routes: { test?: () => Response; save?: () => Response }) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input) => {
    const url = String(input)
    if (url.endsWith("/test_github_token")) return routes.test?.() ?? jsonResponse({ credential_test: { ok: false, message: "", details: {} } })
    if (url.endsWith("/credentials")) return routes.save?.() ?? jsonResponse({})
    throw new Error(`unexpected fetch: ${url}`)
  })
}

const okResult = { credential: "github_token", ok: true, message: "Fine-grained token can write workflow files on acme/widgets as octocat.", details: { login: "octocat", scopes: [], missing_scopes: [], fine_grained: true, probed_repository: "acme/widgets", workflow_file_write: true } }

describe("GithubTokenStep", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders the guided steps: settings link, permission checklist, paste field", () => {
    renderStep()

    const link = screen.getByRole("link", { name: /Open fine-grained token settings/ })
    expect(link).toHaveAttribute("href", "https://github.com/settings/personal-access-tokens/new")
    expect(link).toHaveAttribute("target", "_blank")
    expect(screen.getByText(/Set an expiration/)).toBeInTheDocument()
    expect(screen.getByText("Contents")).toBeInTheDocument()
    expect(screen.getByText("Pull requests")).toBeInTheDocument()
    expect(screen.getByText("Workflows")).toBeInTheDocument()
    expect(screen.getByText("Checks")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("ghp_…")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("owner/repo")).toBeInTheDocument()
  })

  it("probes the unsaved token and repository, then enables save on a green result", async () => {
    mockRoutes({ test: () => jsonResponse({ credential_test: okResult }) })
    renderStep()

    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_good" } })
    fireEvent.change(screen.getByPlaceholderText("owner/repo"), { target: { value: "acme/widgets" } })

    await waitFor(() => expect(screen.getByText(/Fine-grained token can write workflow files/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeEnabled()
  })

  it("keeps save disabled when a fine-grained token only authenticates the user", async () => {
    const needsRepository = {
      credential: "github_token",
      ok: false,
      message: "Fine-grained token authenticated as octocat. Enter a repository slug so Syrus can verify repository write and GitHub Actions workflow-file access before saving.",
      details: { login: "octocat", scopes: [], missing_scopes: [], fine_grained: true, needs_repository_probe: true }
    }
    mockRoutes({ test: () => jsonResponse({ credential_test: needsRepository }) })
    renderStep()

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "github_pat_good" } })

    const line = await screen.findByText(/Enter a repository slug/)
    expect(line.closest("p")).toHaveClass("text-warning-text")
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
  })

  it("shows the authenticated-but-underscoped result as an amber warning and blocks save", async () => {
    const underScoped = {
      credential: "github_token",
      ok: false,
      message: "Token authenticated as octocat, but it is missing the workflow scope.",
      details: { login: "octocat", scopes: ["repo"], missing_scopes: ["workflow"] }
    }
    mockRoutes({ test: () => jsonResponse({ credential_test: underScoped }) })
    renderStep()

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_partial" } })

    const line = await screen.findByText(/missing the workflow scope/)
    expect(line.closest("p")).toHaveClass("text-warning-text")
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
  })

  it("shows a red error and blocks save when GitHub rejects the token outright", async () => {
    const rejected = { credential: "github_token", ok: false, message: "GitHub rejected this token.", details: {} }
    mockRoutes({ test: () => jsonResponse({ credential_test: rejected }) })
    renderStep()

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "nope" } })

    const line = await screen.findByText(/GitHub rejected this token/)
    expect(line.closest("p")).toHaveClass("text-danger-text")
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
  })

  it("saves via a partial PATCH containing only the token, then calls onSaved", async () => {
    const fetchSpy = mockRoutes({
      test: () => jsonResponse({ credential_test: okResult }),
      save: () => jsonResponse({ message: "Credentials updated." })
    })
    const onSaved = vi.fn()
    renderStep({ onSaved })

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_good" } })
    await waitFor(() => expect(screen.getByRole("button", { name: "Save and continue" })).toBeEnabled())
    fireEvent.click(screen.getByRole("button", { name: "Save and continue" }))

    await waitFor(() => expect(onSaved).toHaveBeenCalledTimes(1))
    const saveCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/credentials"))
    expect(JSON.parse(saveCall?.[1]?.body as string)).toEqual({ user: { github_token: "ghp_good" } })
  })

  it("renders a custom save label when the host surface provides one", () => {
    renderStep({ saveLabel: "Save token" })

    expect(screen.getByRole("button", { name: "Save token" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save and continue" })).not.toBeInTheDocument()
  })

  it("shows the updating note instead of the token form while the backend update has the containers down", async () => {
    // The live probe can only fail during the outage window — a red "GitHub
    // rejected this token" for a perfectly good paste. Gated inside the
    // shared step so the onboarding modal AND the credentials card's Replace
    // editor get the same treatment.
    window.syrusShell = {
      getState: vi.fn().mockResolvedValue({
        updateReadyVersion: null,
        claudeDetected: false,
        skillInstalled: false,
        skillOfferDismissed: true,
        backendUpdate: { phase: "migrating", percent: null, outage: true }
      }),
      onStateChanged: vi.fn().mockReturnValue(() => {}),
      relaunchToUpdate: vi.fn(),
      installSkill: vi.fn(),
      dismissSkillOffer: vi.fn()
    }
    resetBackendUpdateStoreForTests()

    // Warm the shared store before mounting so the outage is known at render
    // (in the real app ShellNotices has subscribed since app load).
    function Warm() {
      return <span data-testid="warm">{String(useBackendOutage())}</span>
    }
    const warm = render(<Warm />)
    await waitFor(() => expect(screen.getByTestId("warm")).toHaveTextContent("true"))
    warm.unmount()

    const fetchSpy = mockRoutes({})
    renderStep()

    expect(await screen.findByText(/The Syrus backend is updating/)).toBeInTheDocument()
    expect(screen.queryByPlaceholderText("ghp_…")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Save and continue" })).not.toBeInTheDocument()
    expect(fetchSpy).not.toHaveBeenCalled()

    delete window.syrusShell
    resetBackendUpdateStoreForTests()
  })
})
