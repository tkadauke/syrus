import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InboxView } from "./App"

const noop = () => () => {}

describe("job approval", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("submits approval immediately from the popover action", async () => {
    let resolveApproval!: () => void
    const approveJob = vi.fn(
      () =>
        new Promise<void>((resolve) => {
          resolveApproval = resolve
        })
    )
    const bridge: Partial<typeof window.syrusDesktop> = {
      approveJob,
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
          can_checkout: false,
          can_approve: true,
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
        current_user: { admin: false },
        unread_notifications_count: 0
      }),
      fetchNotificationUnreadCount: vi.fn().mockResolvedValue(0),
      localStatus: vi.fn().mockResolvedValue(null),
      onNotificationEvent: vi.fn().mockReturnValue(noop),
      onNavigateToJob: vi.fn().mockReturnValue(noop),
      onDesktopSettingsUpdated: vi.fn().mockReturnValue(noop)
    }
    ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = bridge

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <InboxView instanceUrl="http://syrus.test" />
      </QueryClientProvider>
    )

    fireEvent.click(await screen.findByRole("button", { name: /open actions for job-42/i }))
    fireEvent.click(await screen.findByRole("menuitem", { name: "Approve for landing" }))

    await waitFor(() => expect(approveJob).toHaveBeenCalledTimes(1))
    expect(approveJob).toHaveBeenCalledWith(42)
    expect(bridge).not.toHaveProperty("confirmApproveJob")
    expect(screen.getByText("approved")).toBeDefined()

    await act(async () => resolveApproval())
  })
})
