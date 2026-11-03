import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { useState } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import * as permissionApi from "../../api/permissionRequests"
import * as notificationApi from "../../api/notifications"
import { Modal } from "../Modal"
import { NotificationsBell } from "../Notifications"
import { PermissionInboxDrawer } from "../PermissionInboxDrawer"
import { ActivityProvider } from "./ActivityProvider"

vi.mock("../../api/permissionRequests", async () => {
  const actual = await vi.importActual<typeof import("../../api/permissionRequests")>("../../api/permissionRequests")
  return { ...actual, fetchPermissionRequests: vi.fn(), decidePermissionRequest: vi.fn() }
})
vi.mock("../../api/notifications", async () => {
  const actual = await vi.importActual<typeof import("../../api/notifications")>("../../api/notifications")
  return { ...actual, fetchNotifications: vi.fn(), markNotificationRead: vi.fn(), markAllNotificationsRead: vi.fn() }
})

type Listener = (event: { matches: boolean }) => void
let mobile = true
const listeners = new Set<Listener>()

function setMobile(value: boolean) {
  mobile = value
  act(() => listeners.forEach((listener) => listener({ matches: value })))
}

function request(id: number, purpose: string) {
  return {
    id,
    state: "pending" as const,
    actionable: true,
    purpose,
    requested_by: "agent",
    runtime_role: "implementer",
    created_at: "2026-11-02T00:00:00Z",
    checkpoint_state: "waiting",
    non_actionable_reason: null,
    origin: { type: "Job", id: 42, label: "JOB-42" },
    subject: { type: "User", id: 1, label: "Release agent" },
    repository: null,
    items: []
  }
}

function notification(id: number, body: string, read = false) {
  return {
    id,
    kind: "job_failed",
    body,
    read_at: read ? "2026-11-02T00:00:00Z" : null,
    pr_url: null,
    job_id: null,
    job_title: null,
    target_path: null,
    created_at: "2026-11-02T00:00:00Z"
  }
}

function mockData(approvals = [request(1, "Publish the release note"), request(2, "Delete the cache")]) {
  vi.mocked(permissionApi.fetchPermissionRequests).mockResolvedValue({
    requests: approvals,
    summary: { pending_count: approvals.length, blocked_agent_count: approvals.length },
    pagination: { page: 1, per_page: 50, total: approvals.length, total_pages: 1 }
  } as never)
  vi.mocked(notificationApi.fetchNotifications).mockResolvedValue({
    notifications: [notification(1, "Build failed"), notification(2, "PR merged", true)],
    unread_count: 1,
    pagination: { page: 1, per_page: 20, total: 2, total_pages: 1 }
  } as never)
}

function renderChrome(extra?: React.ReactNode) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const view = render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <ActivityProvider>
          <PermissionInboxDrawer />
          <NotificationsBell initialUnreadCount={1} prefix="" />
          {extra}
        </ActivityProvider>
      </MemoryRouter>
    </QueryClientProvider>
  )
  return { client, ...view }
}

describe("Activity shell", () => {
  beforeEach(() => {
    mobile = true
    listeners.clear()
    window.matchMedia = vi.fn().mockImplementation((query: string) => ({
      get matches() {
        return query.includes("max-width: 767px") ? mobile : false
      },
      addEventListener: (_: string, listener: Listener) => listeners.add(listener),
      removeEventListener: (_: string, listener: Listener) => listeners.delete(listener)
    })) as never
    mockData()
  })
  afterEach(() => {
    document.body.style.overflow = ""
    window.history.replaceState(null, "")
  })

  it("opens directly on Notifications from the bell and Approvals from the shield, with both badge counts", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    expect(within(shell).getByRole("tab", { name: /Notifications/ })).toHaveAttribute("aria-selected", "true")
    expect(await within(shell).findByText("Build failed")).toBeVisible()
    expect(within(shell).getByTestId("activity-count-notifications")).toHaveTextContent("1")
    expect(await within(shell).findByTestId("activity-count-approvals")).toHaveTextContent("2")
    expect(screen.getAllByRole("dialog")).toHaveLength(1)
    expect(document.body.style.overflow).toBe("hidden")

    fireEvent.click(within(shell).getByRole("button", { name: "Close Activity" }))
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(document.body.style.overflow).toBe("")
  })

  it("opens on Approvals from the approval icon and switches tabs without a second overlay", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    expect(within(shell).getByRole("tab", { name: /Approvals/ })).toHaveAttribute("aria-selected", "true")
    expect(await within(shell).findByText("Publish the release note")).toBeVisible()

    fireEvent.click(within(shell).getByRole("tab", { name: /Notifications/ }))
    expect(within(shell).getByText("Build failed")).toBeVisible()
    expect(screen.getAllByRole("dialog")).toHaveLength(1)
  })

  it("keeps each tab's scroll position when switching", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    const approvalsPanel = within(shell).getByRole("tabpanel", { name: /Approvals/, hidden: true })
    approvalsPanel.scrollTop = 120
    fireEvent.click(within(shell).getByRole("tab", { name: /Notifications/ }))
    approvalsPanel.scrollTop = 0
    fireEvent.click(within(shell).getByRole("tab", { name: /Approvals/ }))
    expect(approvalsPanel.scrollTop).toBe(120)
  })

  it("supports arrow-key navigation between tabs", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    const first = within(shell).getByRole("tab", { name: /Notifications/ })
    fireEvent.keyDown(first, { key: "ArrowRight" })
    expect(within(shell).getByRole("tab", { name: /Approvals/ })).toHaveAttribute("aria-selected", "true")
    expect(within(shell).getByRole("tab", { name: /Approvals/ })).toHaveFocus()
  })

  it("closes on Escape and restores focus to the invoking control", async () => {
    renderChrome()
    const trigger = await screen.findByRole("button", { name: /^Approvals/ })
    trigger.focus()
    fireEvent.click(trigger)
    await screen.findByRole("dialog", { name: "Activity" })
    fireEvent.keyDown(document, { key: "Escape" })
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    await waitFor(() => expect(trigger).toHaveFocus())
  })

  it("closes from the browser back gesture and pushes a single history entry", async () => {
    renderChrome()
    const push = vi.spyOn(window.history, "pushState")
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    await screen.findByRole("dialog", { name: "Activity" })
    expect(push).toHaveBeenCalledTimes(1)
    act(() => window.dispatchEvent(new PopStateEvent("popstate")))
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
  })

  it("closes a nested dialog before Activity on Escape and on back", async () => {
    function NestedToggle() {
      const [open, setOpen] = useState(false)
      return (
        <>
          <button onClick={() => setOpen(true)} type="button">
            open nested
          </button>
          <Modal label="Customize rule" onClose={() => setOpen(false)} open={open}>
            <button type="button">inner</button>
          </Modal>
        </>
      )
    }
    renderChrome(<NestedToggle />)
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    await screen.findByRole("dialog", { name: "Activity" })

    fireEvent.click(screen.getByText("open nested"))
    expect(screen.getByRole("dialog", { name: "Customize rule" })).toBeInTheDocument()
    fireEvent.keyDown(document, { key: "Escape" })
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Customize rule" })).not.toBeInTheDocument())
    expect(screen.getByRole("dialog", { name: "Activity" })).toBeInTheDocument()

    fireEvent.click(screen.getByText("open nested"))
    act(() => window.dispatchEvent(new PopStateEvent("popstate")))
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Customize rule" })).not.toBeInTheDocument())
    expect(screen.getByRole("dialog", { name: "Activity" })).toBeInTheDocument()

    act(() => window.dispatchEvent(new PopStateEvent("popstate")))
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Activity" })).not.toBeInTheDocument())
  })

  it("pops its history entry before navigating so no dead overlay entry is left behind", async () => {
    const back = vi.spyOn(window.history, "back")
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    fireEvent.click(await within(shell).findByRole("link", { name: "View all requests" }))
    expect(back).toHaveBeenCalledTimes(1)
    expect(screen.getByRole("dialog", { name: "Activity" })).toBeInTheDocument()
    act(() => window.dispatchEvent(new PopStateEvent("popstate")))
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Activity" })).not.toBeInTheDocument())
  })

  it("marks a notification read from the Activity shell", async () => {
    vi.mocked(notificationApi.markNotificationRead).mockResolvedValue({ notification: notification(1, "Build failed", true), unread_count: 0 } as never)
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    expect(await within(shell).findByTestId("activity-count-notifications")).toHaveTextContent("1")
    const row = (await within(shell).findByText("Build failed")).closest("[role], div") as HTMLElement
    fireEvent.click(row)
    await waitFor(() => expect(notificationApi.markNotificationRead).toHaveBeenCalledWith(1))
  })

  it("layers a nested modal above the shell and isolates later body portals", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    expect(shell).toHaveClass("z-50")
    const late = document.createElement("div")
    document.body.appendChild(late)
    await waitFor(() => expect(late).toHaveAttribute("inert"))
    const live = document.createElement("div")
    live.setAttribute("aria-live", "polite")
    document.body.appendChild(live)
    await Promise.resolve()
    expect(live).not.toHaveAttribute("inert")
    const modalView = render(
      <Modal label="Customize rule" onClose={() => undefined} open>
        <button type="button">inner</button>
      </Modal>
    )
    const modal = screen.getByRole("dialog", { name: "Customize rule" }).parentElement as HTMLElement
    expect(modal.className).toContain("z-50")
    // Equal z-index: the later body child (the modal) paints above the shell.
    expect(shell.compareDocumentPosition(modal) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    modalView.unmount()
    fireEvent.click(within(shell).getByRole("button", { name: "Close Activity" }))
    act(() => window.dispatchEvent(new PopStateEvent("popstate")))
    await waitFor(() => expect(late).not.toHaveAttribute("inert"))
    late.remove()
    live.remove()
  })

  it("closes when the viewport rotates to a desktop width", async () => {
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    await screen.findByRole("dialog", { name: "Activity" })
    setMobile(false)
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Activity" })).not.toBeInTheDocument())
  })

  it("retires an approval live when it disappears from the shared query", async () => {
    const { client } = renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Approvals/ }))
    const shell = await screen.findByRole("dialog", { name: "Activity" })
    await within(shell).findByText("Delete the cache")
    act(() => {
      client.setQueryData(["permission_requests", 1], {
        requests: [{ ...request(2, "Delete the cache"), state: "approved", actionable: false }, request(1, "Publish the release note")],
        summary: { pending_count: 1, blocked_agent_count: 1 },
        pagination: { page: 1, per_page: 50, total: 2, total_pages: 1 }
      })
    })
    await waitFor(() => expect(within(shell).queryByText("Delete the cache")).not.toBeInTheDocument())
    expect(within(shell).getByTestId("activity-count-approvals")).toHaveTextContent("1")
  })

  it("keeps the desktop popover and drawer distinct from the Activity shell", async () => {
    mobile = false
    renderChrome()
    fireEvent.click(await screen.findByRole("button", { name: /^Notifications/ }))
    expect(screen.queryByTestId("activity-shell")).not.toBeInTheDocument()
    expect(await screen.findByText("Build failed")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /^Approvals/ }))
    expect(await screen.findByRole("complementary")).toBeInTheDocument()
    expect(screen.queryByTestId("activity-shell")).not.toBeInTheDocument()
  })
})
