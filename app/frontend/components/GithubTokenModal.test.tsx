import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { GithubTokenModal } from "./GithubTokenModal"

function renderModal(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <GithubTokenModal onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
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

const okResult = { credential: "github_token", ok: true, message: "Token is valid for octocat.", details: { login: "octocat", scopes: ["repo", "workflow"], missing_scopes: [] } }

describe("GithubTokenModal", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("links to GitHub settings and advises classic token, no expiration, repo + workflow scopes", () => {
    renderModal()

    const link = screen.getByRole("link", { name: /Open github.com\/settings\/tokens/ })
    expect(link).toHaveAttribute("href", "https://github.com/settings/tokens")
    expect(link).toHaveAttribute("target", "_blank")
    expect(screen.getByText(/No expiration/)).toBeInTheDocument()
    expect(screen.getByText("repo")).toBeInTheDocument()
    expect(screen.getByText("workflow")).toBeInTheDocument()
  })

  it("tests the token on paste and shows a green check, enabling save", async () => {
    mockRoutes({ test: () => jsonResponse({ credential_test: okResult }) })
    renderModal()

    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_good" } })

    await waitFor(() => expect(screen.getByText("Token is valid for octocat.")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeEnabled()
  })

  it("warns and blocks save when a required scope is missing", async () => {
    const underScoped = {
      credential: "github_token",
      ok: false,
      message: "Token authenticated as octocat, but it is missing the workflow scope. Regenerate a classic token with repo and workflow enabled.",
      details: { login: "octocat", scopes: ["repo"], missing_scopes: ["workflow"] }
    }
    mockRoutes({ test: () => jsonResponse({ credential_test: underScoped }) })
    renderModal()

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_partial" } })

    await waitFor(() => expect(screen.getByText(/missing the workflow scope/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
  })

  it("shows an error and blocks save when GitHub rejects the token", async () => {
    const rejected = { credential: "github_token", ok: false, message: "GitHub rejected this token. Check that you copied the whole value.", details: {} }
    mockRoutes({ test: () => jsonResponse({ credential_test: rejected }) })
    renderModal()

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "nope" } })

    await waitFor(() => expect(screen.getByText(/GitHub rejected this token/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Save and continue" })).toBeDisabled()
  })

  it("saves the token then advances to the GitHub App step (does not close)", async () => {
    const fetchSpy = mockRoutes({
      test: () => jsonResponse({ credential_test: okResult }),
      save: () => jsonResponse({ message: "Credentials updated." })
    })
    const onClose = vi.fn()
    renderModal({ onClose })

    fireEvent.change(screen.getByPlaceholderText("ghp_…"), { target: { value: "ghp_good" } })
    await waitFor(() => expect(screen.getByRole("button", { name: "Save and continue" })).toBeEnabled())
    fireEvent.click(screen.getByRole("button", { name: "Save and continue" }))

    // Non-admin: after the token saves, the flow moves to the GitHub App step
    // (the PAT form is gone) but the modal stays open.
    await waitFor(() => expect(screen.queryByPlaceholderText("ghp_…")).not.toBeInTheDocument())
    expect(screen.getByText(/ask an\s+admin to register it/)).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()

    const saveCall = fetchSpy.mock.calls.find(([url]) => String(url).endsWith("/credentials"))
    expect(JSON.parse(saveCall?.[1]?.body as string)).toEqual({ user: { github_token: "ghp_good" } })
  })

  it("requires both steps: explains both are needed and starts on the token step", () => {
    renderModal()

    expect(screen.getByText(/To monitor and interact with GitHub/)).toHaveTextContent(
      "To monitor and interact with GitHub, and to act as an independent contributor, Syrus requires both a Personal Access Token (PAT) and a custom GitHub App."
    )
    // Both steps are named in the stepper; the token step is active first.
    expect(screen.getByText("Personal access token")).toBeInTheDocument()
    expect(screen.getByText("GitHub App")).toBeInTheDocument()
    expect(screen.getByPlaceholderText("ghp_…")).toBeInTheDocument()
  })

  it("admin: advances to the GitHub App registration after the token is saved", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    client.setQueryData(["bootstrap"], { current_user: { admin: true }, setup_status: { credential_status: { github_pat: true, github_app: false } } })
    vi.spyOn(window, "fetch").mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes("/admin/github_app/register")) {
        return jsonResponse({
          github_app: { registered: false, id: null, slug: null, registered_at: null, install_url: null },
          github_manifest_url: "https://github.com/settings/apps/new?state=abc",
          manifest: "{}",
          submit_label: "Register GitHub App"
        })
      }
      if (url.endsWith("/admin/github_app/confirm")) return jsonResponse({ github_app: { registered: false, id: null, slug: null, registered_at: null, install_url: null } })
      if (url.endsWith("/api/v1/app/bootstrap")) return jsonResponse({ current_user: { admin: true }, setup_status: { credential_status: { github_pat: true, github_app: false } } })
      return jsonResponse({})
    })

    render(
      <QueryClientProvider client={client}>
        <GithubTokenModal onClose={() => {}} />
      </QueryClientProvider>
    )

    // Token already saved (github_token: true) → straight to the App step.
    expect(await screen.findByRole("button", { name: /Register GitHub App/ })).toBeInTheDocument()
    expect(screen.queryByText(/To monitor and interact with GitHub/)).not.toBeInTheDocument()
    expect(screen.queryByPlaceholderText("ghp_…")).not.toBeInTheDocument()
  })
})
