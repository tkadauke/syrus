import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { appendBootstrapScript } from "../test/app/bootstrap"
import { chatPayload, pendingAction } from "../test/app/chatPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat pending actions", () => {
  installAppTestLifecycle()

  it("renders pending action cards one at a time in the bottom carousel", async () => {
    const pending = {
      id: 7,
      label: "Cancel job",
      detail: "Cancel **this job** before it lands.\n\n- Notify reviewers.",
      action: "cancel_job",
      state: "pending",
      resource_title: "Refactor checkout flow",
      resource_url: "/jobs/44",
      app_confirm_path: "/api/v1/app/chats/8/pending_actions/7/confirm",
      app_reject_path: "/api/v1/app/chats/8/pending_actions/7/reject"
    }
    const confirmed = {
      id: 8,
      label: "Retry job",
      action: "retry_job",
      state: "confirmed",
      resource_title: "Retry flaky build",
      resource_url: "/jobs/45",
      app_confirm_path: "/api/v1/app/chats/8/pending_actions/8/confirm",
      app_reject_path: "/api/v1/app/chats/8/pending_actions/8/reject"
    }
    const rejected = {
      id: 9,
      label: "Submit feedback",
      action: "submit_chat_feedback",
      state: "rejected",
      app_confirm_path: "/api/v1/app/chats/8/pending_actions/9/confirm",
      app_reject_path: "/api/v1/app/chats/8/pending_actions/9/reject"
    }
    const payload = chatPayload({
      messages: [
        { ...chatPayload().messages[0], id: 12, text: "This needs confirmation.", content: { text: "This needs confirmation." } },
        { ...chatPayload().messages[0], id: 13, text: "Already handled.", content: { text: "Already handled." } },
        { ...chatPayload().messages[0], id: 14, text: "No link action.", content: { text: "No link action." } }
      ],
      pendingActions: [pending, confirmed, rejected]
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/pending_actions/7/reject" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              ...payload,
              pending_actions: [{ ...pending, state: "rejected" }, confirmed, rejected]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("This needs confirmation.")).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Cancel job" })).toBeInTheDocument()
    expect(screen.getByText((_content, element) => element?.tagName === "P" && element.textContent === "Cancel this job before it lands.")).toBeInTheDocument()
    expect(screen.getByText("this job").tagName).toBe("STRONG")
    expect(screen.getByText("Notify reviewers.").tagName).toBe("LI")
    expect(screen.getByRole("link", { name: "Refactor checkout flow" })).toHaveAttribute("href", "/jobs/44")
    expect(screen.getByRole("button", { name: "Confirm" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Decline" })).toBeInTheDocument()
    expect(screen.getByText("1 of 3")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Retry job" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))
    expect(screen.getByRole("heading", { name: "Retry job" })).toBeInTheDocument()
    expect(screen.getAllByText("Confirmed").length).toBeGreaterThan(0)
    expect(screen.queryByRole("heading", { name: "Cancel job" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))
    expect(screen.getByRole("heading", { name: "Submit feedback" })).toBeInTheDocument()
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    expect(screen.queryByRole("link", { name: "Submit feedback" })).not.toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Previous pending action" }))
    fireEvent.click(screen.getByRole("button", { name: "Previous pending action" }))
    fireEvent.click(screen.getByRole("button", { name: "Decline" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/chats/8/pending_actions/7/reject", expect.objectContaining({ method: "POST" }))
    })
  })

  it("renders proposal dependency pills with confirmed and pending badges", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal proposed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "syrus_issue",
        kind_label: "Syrus issue",
        state: "proposed",
        state_label: "Proposed",
        title: "Search cards",
        slug: "search-cards",
        body: "Show dependency status.",
        proposed: true,
        resolved: false,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependency_slugs: ["chat-search-fts5", "agent-memory"],
        dependencies: [
          {
            slug: "chat-search-fts5",
            title: "Chat FTS5 infrastructure",
            state: "confirmed",
            confirmed: true,
            anchor_message_id: 9,
            materialized_path: "/jobs/41"
          },
          {
            slug: "agent-memory",
            title: "Agent Memory System",
            state: "proposed",
            confirmed: false,
            anchor_message_id: null,
            materialized_path: null
          },
          {
            slug: "foundation-epic",
            title: "foundation-epic",
            display_label: "foundation-epic",
            state: "unresolved",
            confirmed: false,
            anchor_message_id: null,
            materialized_path: null
          },
          {
            slug: "epic:42",
            title: "EPIC-42",
            display_label: "EPIC-42",
            state: "ready",
            confirmed: true,
            anchor_message_id: null,
            materialized_path: "/epics/42"
          }
        ],
        has_dependencies: true,
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null
      }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Depends on:")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Chat FTS5 infrastructure ✓" })).toHaveAttribute("href", "#message-9")
    expect(screen.getByText("Agent Memory System ⏳")).toBeInTheDocument()
    expect(screen.getByText("foundation-epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-42" })).toHaveAttribute("href", "/app-shell/epics/42")
  })

  it("renders a muted no-dependencies strip on proposal cards", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal proposed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "job",
        kind_label: "Job",
        state: "proposed",
        state_label: "Proposed",
        title: "Map auth",
        slug: "map-auth",
        body: "Map it.",
        proposed: true,
        resolved: false,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependency_slugs: [],
        dependencies: [],
        has_dependencies: false,
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null
      }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("No dependencies")).toHaveClass("text-gray-500")
  })

  it("renders queued pending actions as waiting without action buttons", async () => {
    appendBootstrapScript()

    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload({
              pendingActions: [pendingAction({ id: 7, label: "Send feedback to JOB-44", state: "queued" })]
            })
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("link", { name: "JOB-44" })).toHaveAttribute("href", "/jobs/JOB-44")
    expect(screen.getByText("Waiting…")).toBeInTheDocument()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument()
  })

  it("renders confirming and failed pending actions with execution details", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload({
              pendingActions: [
                pendingAction({ id: 7, label: "Cancel JOB-44", state: "confirming", executionStatus: "running", executionStep: "Cancelling workflow..." }),
                pendingAction({
                  id: 8,
                  label: "Retry JOB-45",
                  state: "failed",
                  executionStatus: "failed",
                  executionStep: "Failed.",
                  executionError: "ArgumentError: Job is not accessible."
                })
              ]
            })
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Working…")).toBeInTheDocument()
    expect(screen.getAllByText("Cancelling workflow...")).toHaveLength(1)
    expect(screen.queryByText("ArgumentError: Job is not accessible.")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))
    expect(screen.getAllByText("Failed").length).toBeGreaterThan(0)
    expect(screen.getByText("ArgumentError: Job is not accessible.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
  })

  it("renders linked pending actions below the message stream in the bottom carousel", async () => {
    appendBootstrapScript()

    const userMessage = {
      type: "message",
      id: 11,
      role: "user",
      tool_name: null,
      content: { text: "Please send this feedback." },
      text: "Please send this feedback.",
      bookmarkable: true
    }
    const linkedMessage = {
      type: "message",
      id: 12,
      role: "assistant",
      tool_name: null,
      content: { text: "Feedback queued for confirmation." },
      text: "Feedback queued for confirmation.",
      bookmarkable: true
    }
    const laterMessage = {
      type: "message",
      id: 13,
      role: "assistant",
      tool_name: null,
      content: { text: "A later assistant message." },
      text: "A later assistant message.",
      bookmarkable: true
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload({
              messages: [userMessage, linkedMessage, laterMessage],
              pendingActions: [
                pendingAction({
                  id: 7,
                  label: "Send feedback to JOB-44",
                  detail: "Please **tighten** this implementation.\n\n- Use focused tests.",
                  chatMessageId: 12
                })
              ]
            })
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const linkedText = await screen.findByText("Feedback queued for confirmation.")
    const actionHeading = screen.getByRole("heading", { name: "Send feedback to JOB-44" })
    const laterText = screen.getByText("A later assistant message.")
    const linkedArticle = linkedText.closest("article")!
    const actionCard = actionHeading.closest("article")!
    const laterArticle = laterText.closest("article")!

    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
    expect(linkedArticle.compareDocumentPosition(actionCard) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(laterArticle.compareDocumentPosition(actionCard) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.getByRole("link", { name: "JOB-44" })).toHaveAttribute("href", "/jobs/JOB-44")
    expect(
      screen.getByText((_content, element) => element?.tagName === "P" && element.textContent === "Please tighten this implementation.")
    ).toBeInTheDocument()
    expect(screen.getByText("tighten").tagName).toBe("STRONG")
    expect(screen.getByText("Use focused tests.").tagName).toBe("LI")
  })

  it("renders unanchored pending actions after the last message", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload({
              messages: [
                { ...chatPayload().messages[0], id: 11, text: "First message.", content: { text: "First message." } },
                { ...chatPayload().messages[0], id: 12, text: "Last message.", content: { text: "Last message." } }
              ],
              pendingActions: [pendingAction({ id: 7, label: "Send feedback to JOB-44", chatMessageId: null })]
            })
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const lastText = await screen.findByText("Last message.")
    const actionHeading = screen.getByRole("heading", { name: "Send feedback to JOB-44" })
    expect(lastText.closest("article")!.compareDocumentPosition(actionHeading.closest("article")!) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(screen.queryByRole("heading", { name: "Pending actions" })).not.toBeInTheDocument()
  })

  it("renders terminal pending actions as read-only badges", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload({
              pendingActions: [
                pendingAction({ id: 7, label: "Cancel JOB-44", state: "confirmed" }),
                pendingAction({ id: 8, label: "Retry JOB-45", state: "rejected" }),
                pendingAction({ id: 9, label: "Rebase JOB-46", state: "cancelled" })
              ]
            })
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Cancel JOB-44")).toBeInTheDocument()
    expect(screen.getAllByText("Confirmed").length).toBeGreaterThan(0)
    expect(screen.queryByText("Retry JOB-45")).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole("button", { name: "Next pending action" }))
    expect(screen.getAllByText("Cancelled").length).toBeGreaterThan(0)
    expect(screen.queryByRole("button", { name: "Confirm" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Cancel" })).not.toBeInTheDocument()
  })

  it("links confirmed Epic proposals to the Epic detail route", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Epic proposal confirmed.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "epic",
        kind_label: "Epic",
        state: "confirmed",
        state_label: "Confirmed",
        title: "Raise the forum",
        slug: "raise-the-forum",
        body: "Let the forum stand.",
        proposed: false,
        resolved: true,
        epic_bundle: true,
        scoped_repository_slug: "acme/widgets",
        dependencies: [],
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: "EPIC-11",
        materialized_path: "/epics/11",
        materialized: {
          kind: "epic",
          epic_id: 11,
          epic_title: "Raise the forum",
          child_jobs: [
            { job_id: 154, title: "Add inspection tools" },
            { job_id: 155, title: "Add trigger" }
          ]
        },
        active_children_count: 0,
        children: []
      }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Copy EPIC-11 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Raise the forum" })).toHaveAttribute("href", "/app-shell/epics/11")
    expect(screen.getByText((_, element) => element?.textContent === '→ EPIC-11 "Raise the forum"')).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy JOB-154 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy JOB-155 to clipboard" })).toBeInTheDocument()
    expect(screen.getByText((_, element) => element?.textContent === 'Jobs: JOB-154 "Add inspection tools", JOB-155 "Add trigger"')).toBeInTheDocument()
  })

  it("shows rejected proposal state on proposal cards", async () => {
    const proposalMessage = {
      type: "message",
      id: 10,
      role: "assistant",
      text: "Proposal rejected.",
      bookmarkable: true,
      proposal: {
        id: 5,
        kind: "job",
        kind_label: "Job",
        state: "rejected",
        state_label: "Rejected",
        title: "Map auth",
        slug: "map-auth",
        body: "Map it.",
        proposed: false,
        resolved: true,
        epic_bundle: false,
        scoped_repository_slug: "acme/widgets",
        dependencies: [],
        target_epic_label: null,
        app_confirm_path: "/api/v1/app/chats/8/proposals/5/confirm",
        app_reject_path: "/api/v1/app/chats/8/proposals/5/reject",
        materialized_label: null,
        materialized_path: null,
        materialized: { kind: "rejected", reason: "rejected" }
      }
    }
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(JSON.stringify(chatPayload({ messages: [...chatPayload().messages, proposalMessage] })), {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("heading", { name: "Map auth" })).toBeInTheDocument()
    expect(screen.getAllByText("Rejected").length).toBeGreaterThan(0)
    expect(screen.queryByText(/Job\s+#/)).not.toBeInTheDocument()
  })
})
