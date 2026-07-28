import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InboxView } from "./App"

const noop = () => () => {}

function stubBridge(over: Partial<typeof window.syrusDesktop> = {}) {
  const bridge: Partial<typeof window.syrusDesktop> = {
    fetchInboxJobs: vi.fn().mockResolvedValue([
      {
        id: 42,
        title: "Test job",
        state: "implemented",
        summary_state: "implemented",
        repository_slug: "owner/repo",
        branch_name: "syrus/issue-42",
        pr_number: null,
        pr_url: null,
        issue_number: 1,
        priority: "medium",
        epic_id: null,
        can_checkout: true,
        can_approve: false,
        can_retry: false,
        checkout_status: null,
        github_issue_url: null,
        github_pr_url: null,
        owner_user_id: 1,
        claimed_by_user_id: null
      }
    ]),
    syrusCliStatus: vi.fn().mockResolvedValue({ available: true, bundledAvailable: true }),
    fetchBootstrap: vi.fn().mockResolvedValue({
      current_user: { admin: false, notification_preferences: {} },
      unread_notifications_count: 0
    }),
    fetchNotificationUnreadCount: vi.fn().mockResolvedValue(0),
    // Required for checkoutEnabled = true
    checkoutAvailability: vi.fn().mockResolvedValue({ localPath: "/projects/owner/repo", cliAvailable: true }),
    localStatus: vi.fn().mockResolvedValue(null),
    // Event subscriptions used in useEffect cleanup
    onNotificationEvent: vi.fn().mockReturnValue(noop),
    onNavigateToJob: vi.fn().mockReturnValue(noop),
    onDesktopSettingsUpdated: vi.fn().mockReturnValue(noop),
    ...over
  }
  ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = bridge
  return bridge
}

function renderInboxView() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <InboxView instanceUrl="http://syrus.test" />
    </QueryClientProvider>
  )
}

describe("checkout overlay", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("shows a spinner overlay while checkoutJob is in flight and removes it on completion", async () => {
    let resolveCheckout!: (value: { branchName: string }) => void
    const checkoutJob = vi.fn(
      () =>
        new Promise<{ branchName: string }>((resolve) => {
          resolveCheckout = resolve
        })
    )
    stubBridge({ checkoutJob })

    renderInboxView()

    // Wait for the job list to load, then open the actions menu
    const actionsMenuBtn = await screen.findByRole("button", { name: /open actions for job-42/i })
    expect(screen.queryByRole("status", { name: /checking out branch/i })).toBeNull()
    fireEvent.click(actionsMenuBtn)

    // Click "Checkout locally" in the dropdown — overlay should appear immediately
    const checkoutMenuItem = await screen.findByRole("menuitem", { name: /checkout locally/i })
    fireEvent.click(checkoutMenuItem)

    await waitFor(() => {
      expect(screen.getByRole("status", { name: /checking out branch/i })).toBeDefined()
    })

    // Resolve the checkout — overlay should disappear
    await act(async () => {
      resolveCheckout({ branchName: "syrus/issue-42" })
    })
    await waitFor(() => {
      expect(screen.queryByRole("status", { name: /checking out branch/i })).toBeNull()
    })
  })

  it("removes the overlay even when checkoutJob rejects", async () => {
    let rejectCheckout!: (err: Error) => void
    const checkoutJob = vi.fn(
      () =>
        new Promise<{ branchName: string }>((_resolve, reject) => {
          rejectCheckout = reject
        })
    )
    stubBridge({ checkoutJob })

    renderInboxView()

    const actionsMenuBtn = await screen.findByRole("button", { name: /open actions for job-42/i })
    fireEvent.click(actionsMenuBtn)

    const checkoutMenuItem = await screen.findByRole("menuitem", { name: /checkout locally/i })
    fireEvent.click(checkoutMenuItem)

    await waitFor(() => {
      expect(screen.getByRole("status", { name: /checking out branch/i })).toBeDefined()
    })

    await act(async () => {
      rejectCheckout(new Error("network error"))
    })
    await waitFor(() => {
      expect(screen.queryByRole("status", { name: /checking out branch/i })).toBeNull()
    })
  })
})
