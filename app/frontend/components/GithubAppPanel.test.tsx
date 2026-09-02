import { jsonResponse } from "../testSupport"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { GithubAppPanel } from "./GithubAppPanel"

function renderPanel(props: { onClose?: () => void; onSaved?: () => void; confirmRefetchIntervalMs?: number } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <GithubAppPanel confirmRefetchIntervalMs={props.confirmRefetchIntervalMs} onClose={props.onClose ?? (() => {})} onSaved={props.onSaved} />
    </QueryClientProvider>
  )
}

const notRegistered = { registered: false, id: null, slug: null, registered_at: null, install_url: null, installations: [] }
const registered = { registered: true, id: 42, slug: "operator-syrus", registered_at: "2026-06-20T00:00:00Z", install_url: "https://github.com/apps/operator-syrus/installations/new", installations: [] }
const installed = { ...registered, installations: [{ account_login: "octocat", account_type: "User" }] }
const bounceUrl = "http://localhost:3000/admin/github_app/manifest?state=abc&syrus_external=1"

function mockRoutes(over: { register?: () => Response; confirm?: () => Response; sync?: () => Response } = {}) {
  return vi.spyOn(window, "fetch").mockImplementation(async (input) => {
    const url = String(input)
    if (url.includes("/admin/github_app/register")) {
      return over.register?.() ?? jsonResponse({
        github_app: notRegistered,
        bounce_url: bounceUrl,
        submit_label: "Register GitHub App"
      })
    }
    if (url.endsWith("/admin/github_app/confirm")) return over.confirm?.() ?? jsonResponse({ github_app: notRegistered })
    if (url.endsWith("/admin/github_app/sync_installations")) return over.sync?.() ?? jsonResponse({ enqueued: true })
    throw new Error(`unexpected fetch: ${url}`)
  })
}

describe("GithubAppPanel", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("renders the registration button when the App is not registered", async () => {
    mockRoutes()
    renderPanel()

    await screen.findByRole("button", { name: /Register GitHub App/ })
    expect(screen.getByText("The GitHub App enables actions to appear as a bot natively on your repositories.")).toBeInTheDocument()
    expect(screen.queryByText(/recommended credential/)).not.toBeInTheDocument()
  })

  it("offers the account-level install once registered, and detects the installation", async () => {
    let confirmedInstall = false
    mockRoutes({
      register: () => jsonResponse({ github_app: registered, bounce_url: bounceUrl, submit_label: "Re-register GitHub App" }),
      confirm: () => jsonResponse({ github_app: confirmedInstall ? installed : registered })
    })
    const opened = { opener: {} as unknown }
    const openSpy = vi.spyOn(window, "open").mockReturnValue(opened as Window)
    const onSaved = vi.fn()
    renderPanel({ onSaved, confirmRefetchIntervalMs: 10 })

    expect(await screen.findByText("The Syrus GitHub App is registered.")).toBeInTheDocument()
    expect(screen.getByText(/All repositories/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Skip for now" })).toBeInTheDocument()
    await waitFor(() => expect(onSaved).toHaveBeenCalled())

    fireEvent.click(screen.getByRole("button", { name: /Install on GitHub/ }))
    expect(openSpy).toHaveBeenCalledWith("https://github.com/apps/operator-syrus/installations/new", "_blank")
    await waitFor(() => expect(screen.getByText(/Waiting for GitHub/)).toBeInTheDocument())

    // The panel nudges the server-side installation sync while waiting.
    const fetchSpy = window.fetch as ReturnType<typeof vi.fn>
    await waitFor(() =>
      expect(fetchSpy.mock.calls.some(([u]) => String(u).endsWith("/admin/github_app/sync_installations"))).toBe(true)
    )

    // Once the sync links the installation, the panel flips by itself.
    confirmedInstall = true
    await waitFor(() => expect(screen.getByText(/Installed on octocat/)).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Done" })).toBeInTheDocument()
  })

  it("shows the installed state directly when an installation already exists", async () => {
    mockRoutes({
      register: () => jsonResponse({ github_app: installed, bounce_url: bounceUrl, submit_label: "Re-register GitHub App" }),
      confirm: () => jsonResponse({ github_app: installed })
    })
    renderPanel()

    expect(await screen.findByText(/Installed on octocat/)).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Install on GitHub/ })).not.toBeInTheDocument()
  })

  it("falls back to a note when the user is not an admin (403)", async () => {
    mockRoutes({ register: () => jsonResponse({ error: { message: "Admin access required." } }, 403) })
    renderPanel()

    await waitFor(() => expect(screen.getByText(/Only an admin can register/)).toBeInTheDocument())
  })

  it("opens the bounce page in a new tab and starts polling", async () => {
    const fetchSpy = mockRoutes()
    const opened = { opener: {} as unknown }
    const openSpy = vi.spyOn(window, "open").mockReturnValue(opened as Window)
    renderPanel()

    fireEvent.click(await screen.findByRole("button", { name: /Register GitHub App/ }))

    expect(openSpy).toHaveBeenCalledWith(bounceUrl, "_blank")
    expect(opened.opener).toBeNull()
    await waitFor(() => expect(screen.getByText(/Waiting for GitHub to finish/)).toBeInTheDocument())
    expect(screen.queryByText(/Popup blocked/)).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalled()
  })

  it("offers a manual link when the popup is blocked in a plain browser", async () => {
    mockRoutes()
    vi.spyOn(window, "open").mockReturnValue(null)
    renderPanel()

    fireEvent.click(await screen.findByRole("button", { name: /Register GitHub App/ }))

    const manual = await screen.findByRole("link", { name: /Open the registration page/ })
    expect(manual).toHaveAttribute("href", bounceUrl)
  })

  it("treats a null window.open as success inside the desktop shell", async () => {
    mockRoutes()
    vi.spyOn(window, "open").mockReturnValue(null)
    vi.spyOn(navigator, "userAgent", "get").mockReturnValue("Mozilla/5.0 Electron/39.0.0 SyrusDesktop/0.1.0")
    renderPanel()

    fireEvent.click(await screen.findByRole("button", { name: /Register GitHub App/ }))

    await waitFor(() => expect(screen.getByText(/Waiting for GitHub to finish/)).toBeInTheDocument())
    expect(screen.queryByText(/Popup blocked/)).not.toBeInTheDocument()
  })
})
