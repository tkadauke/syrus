import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { GithubAppPanel } from "./GithubAppPanel"

function renderPanel(props: { onClose?: () => void; onSaved?: () => void } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <GithubAppPanel onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } })
}

const notRegistered = { registered: false, id: null, slug: null, registered_at: null, install_url: null }
const registered = { registered: true, id: 42, slug: "operator-syrus", registered_at: "2026-06-20T00:00:00Z", install_url: "https://github.com/apps/operator-syrus/installations/new" }

function mockRoutes(over: { register?: () => Response; confirm?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input) => {
    const url = String(input)
    if (url.includes("/admin/github_app/register")) {
      return over.register?.() ?? jsonResponse({
        github_app: notRegistered,
        github_manifest_url: "https://github.com/settings/apps/new?state=abc",
        manifest: "{\"name\":\"syrus\"}",
        submit_label: "Register GitHub App"
      })
    }
    if (url.endsWith("/admin/github_app/confirm")) return over.confirm?.() ?? jsonResponse({ github_app: notRegistered })
    throw new Error(`unexpected fetch: ${url}`)
  })
}

describe("GithubAppPanel", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders the manifest registration form when the App is not registered", async () => {
    mockRoutes()
    renderPanel()

    const button = await screen.findByRole("button", { name: /Register GitHub App/ })
    expect(screen.getByText("The GitHub App enables actions to appear as a bot natively on your repositories.")).toBeInTheDocument()
    expect(screen.queryByText(/recommended credential/)).not.toBeInTheDocument()
    const form = button.closest("form") as HTMLFormElement
    expect(form).toHaveAttribute("action", "https://github.com/settings/apps/new?state=abc")
    expect(form).toHaveAttribute("method", "post")
    expect(form.querySelector("input[name='manifest']")).toHaveValue("{\"name\":\"syrus\"}")
  })

  it("shows the install link and Done once registered", async () => {
    mockRoutes({ register: () => jsonResponse({ github_app: registered, github_manifest_url: "x", manifest: "{}", submit_label: "Re-register GitHub App" }), confirm: () => jsonResponse({ github_app: registered }) })
    const onSaved = vi.fn()
    renderPanel({ onSaved })

    const install = await screen.findByRole("link", { name: /Install the Syrus App on GitHub/ })
    expect(install).toHaveAttribute("href", "https://github.com/apps/operator-syrus/installations/new")
    expect(screen.getByRole("button", { name: "Done" })).toBeInTheDocument()
    expect(screen.queryByText(/install now or later/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Open Repositories later/)).not.toBeInTheDocument()
    await waitFor(() => expect(onSaved).toHaveBeenCalled())
  })

  it("falls back to a note when the user is not an admin (403)", async () => {
    mockRoutes({ register: () => jsonResponse({ error: { message: "Admin access required." } }, 403) })
    renderPanel()

    await waitFor(() => expect(screen.getByText(/Only an admin can register/)).toBeInTheDocument())
  })

  it("starts polling after the operator submits the manifest form", async () => {
    const fetchSpy = mockRoutes()
    renderPanel()

    const button = await screen.findByRole("button", { name: /Register GitHub App/ })
    // jsdom can't submit cross-origin; fire submit on the form directly.
    const form = button.closest("form") as HTMLFormElement
    form.addEventListener("submit", (e) => e.preventDefault())
    fireEvent.submit(form)

    await waitFor(() => expect(screen.getByText(/Waiting for GitHub to finish/)).toBeInTheDocument())
    expect(fetchSpy).toHaveBeenCalled()
  })
})
