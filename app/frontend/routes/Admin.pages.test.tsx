import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { appendBootstrapScript, bootstrapPayload, sidebarPluginPagesPayload } from "../test/app/bootstrap"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App admin pages", () => {
  installAppTestLifecycle()

  it("renders the admin overview route from the app admin API", async () => {
    const script = document.createElement("script")
    script.id = "syrus-bootstrap-data"
    script.type = "application/json"
    script.textContent = JSON.stringify(bootstrapPayload())
    document.body.appendChild(script)
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            active_runs: { total: 2, by_trigger: { initial: 1, retry: 1 } },
            queued_runs: { total: 1 },
            recent_failures_24h: { total: 0, by_trigger: {} },
            github_rate_limits: [],
            github_api_blocked_users: [],
            provider_circuits: [],
            agent_session_capture_rate: { total: 3, captured: 3, rate: 1.0 },
            data_root_disk_usage: {
              path: "/syrus-home/.syrus",
              filesystem: "/dev/pvc",
              total_bytes: 100,
              used_bytes: 90,
              available_bytes: 10,
              used_percent: 90,
              mounted_on: "/syrus-home",
              observed_at: "2026-06-05T12:00:00Z",
              level: "warning"
            },
            resource_admission: {
              generated_at: "2026-06-05T12:00:00Z",
              windows: { recent_hours: 24, delayed_hours: 6 },
              active_consumers: [],
              recent_top_consumers: [],
              delayed_work: [],
              low_confidence_profiles: [],
              admission_overrides: []
            },
            chat_scoped_events: {
              window_hours: 24,
              total: 3,
              by_state: { completed: 2, failed: 1 },
              by_decision: { no_op: 1, respond: 1, act: 0 },
              failures: [
                {
                  id: 8,
                  source_kind: "workflow_failed",
                  summary: "Workflow evaluator failed",
                  delivery_state: "pending",
                  evaluator_state: "failed",
                  error: "JSON::ParserError: evaluator did not return JSON",
                  created_at: "2026-06-05T11:00:00Z",
                  chat: { id: 4, title: "Ops", path: "/chats/4" },
                  job: { id: 12, slug: "JOB-12", path: "/jobs/12" }
                }
              ],
              recent: [
                {
                  id: 9,
                  source_kind: "workflow_failed",
                  summary: "Workflow failed",
                  severity: "critical",
                  delivery_state: "delivered",
                  evaluator_state: "completed",
                  decision: "respond",
                  reason: "operator should know",
                  created_at: "2026-06-05T11:01:00Z",
                  chat: { id: 4, title: "Ops", path: "/chats/4" },
                  repository: { id: 2, slug: "acme/widgets" },
                  job: { id: 12, slug: "JOB-12", path: "/jobs/12" }
                }
              ]
            },
            workers: { total: 1, stale: 1 },
            worker_health: {
              generated_at: "2026-06-05T12:00:00Z",
              range: { since: "2026-06-04T12:00:00Z", until: "2026-06-05T12:00:00Z" },
              current_sample_window_seconds: 900,
              minute_bucket: { granularity_seconds: 60, window_minutes: 60, max_window_minutes: 1440 },
              current: [],
              hosts: []
            },
            recurring: { count: 2, overdue: [{ key: "poll_repositories", age_seconds: 660 }] },
            stuck_pagination: { page: 1, per_page: 50, total: 1, total_pages: 1, first_item: 1, last_item: 1, previous_path: null, next_path: null },
            stuck: [
              {
                kind: "stale_heartbeat",
                severity: "warn",
                detail: "Run #4 silent for 10m",
                age_label: "10m",
                run_id: 4,
                workflow_id: 2,
                workflow_slug: "WF-2",
                workflow_path: "/jobs/1?tab=workflows#workflow-2",
                workflow_trigger_kind: "initial",
                step_kind: "implement",
                job_id: 1,
                job_path: "/jobs/1"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/admin"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      expect(await screen.findByText("Active runs")).toBeInTheDocument()
      expect(screen.getByRole("main", { name: "Admin overview" })).toBeInTheDocument()
      const adminNav = screen.getByRole("navigation", { name: "Admin" })
      expect(within(adminNav).getByRole("link", { name: "Overview" })).toHaveAttribute("href", "/app-shell/admin")
      expect(within(adminNav).getByRole("link", { name: "Resource Admission" })).toHaveAttribute("href", "/app-shell/admin/resource_admission")
      expect(within(adminNav).getByRole("link", { name: "Scoped Chat Events" })).toHaveAttribute("href", "/app-shell/admin/scoped_chat_events")
      expect(within(adminNav).getByRole("link", { name: "Workflow Events" })).toHaveAttribute("href", "/app-shell/admin/activity")
      expect(within(adminNav).getByRole("link", { name: "Reconciler Events" })).toHaveAttribute("href", "/app-shell/admin/reconciler_activity")
      expect(within(adminNav).getByRole("link", { name: "Stuck" })).toHaveAttribute("href", "/app-shell/admin/stuck")
      expect(within(adminNav).getByRole("link", { name: "Users" })).toHaveAttribute("href", "/app-shell/admin/users")
      expect(within(adminNav).getByRole("link", { name: "Queue" })).toHaveAttribute("href", "/app-shell/admin/queue")
      expect(within(adminNav).getByRole("link", { name: "Processes" })).toHaveAttribute("href", "/app-shell/admin/processes")
      expect(within(adminNav).getByRole("link", { name: "Console" })).toHaveAttribute("href", "/app-shell/admin/console")
      expect(within(adminNav).getByRole("link", { name: "GitHub App" })).toHaveAttribute("href", "/app-shell/admin/github_app/register")
      expect(within(adminNav).getByRole("link", { name: "Installations" })).toHaveAttribute("href", "/app-shell/admin/installations")
      expect(within(adminNav).getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/app-shell/settings/edit")
      expect(within(adminNav).getByRole("link", { name: "Invitations" })).toHaveAttribute("href", "/app-shell/invitations")
      expect(screen.getByRole("link", { name: /Active runs/ })).toHaveAttribute("href", "/app-shell/admin/queue/active")
      expect(screen.getByText("Data root disk")).toBeInTheDocument()
      expect(screen.getByText("90%")).toBeInTheDocument()
      expect(screen.queryByRole("link", { name: /Stuck things/ })).not.toBeInTheDocument()
      expect(screen.queryByRole("link", { name: "Run #4 silent for 10m" })).not.toBeInTheDocument()
      expect(screen.queryByRole("region", { name: "Scoped chat event evaluator decisions" })).not.toBeInTheDocument()
      expect(screen.queryByText("JSON::ParserError: evaluator did not return JSON")).not.toBeInTheDocument()
      expect(screen.getByRole("link", { name: /Workers/ })).toHaveClass("border-red-200")
      const recurringMetric = screen.getByRole("link", { name: /Recurring jobs/ })
      expect(recurringMetric).toHaveClass("border-red-200")
      expect(within(recurringMetric).getByText("poll_repositories")).toBeInTheDocument()
      expect(within(recurringMetric).getByText("2")).toBeInTheDocument()
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/overview?page=recurring", expect.anything())
    } finally {
      script.remove()
    }
  })

  it("renders admin resource admission and scoped chat event subpages", async () => {
    const payload = {
      active_runs: { total: 0, by_trigger: {} },
      queued_runs: { total: 0 },
      recent_failures_24h: { total: 0, by_trigger: {} },
      github_rate_limits: [],
      github_api_blocked_users: [],
      provider_circuits: [],
      agent_session_capture_rate: { total: 0, captured: 0, rate: null },
      data_root_disk_usage: null,
      resource_admission: {
        generated_at: "2026-06-05T12:00:00Z",
        windows: { recent_hours: 24, delayed_hours: 6 },
        active_consumers: [],
        recent_top_consumers: [],
        delayed_work: [
          {
            workflow_id: 12,
            workflow_path: "/jobs/7?tab=workflows#workflow-12",
            reason: "workflow_admission_budget",
            action: "delay",
            next_check_at: "2026-06-05T12:05:00Z",
            estimated_remaining_cost: 2.5,
            details: {
              worker_pressure_scope: "localized",
              pressured_worker_storage_keys: [
                {
                  storage_key: "storage-critical",
                  hostnames: ["worker-compute-critical", "worker-home-critical"],
                  health_level: "critical"
                }
              ],
              healthy_alternative_worker_storage_keys: [
                {
                  storage_key: "storage-healthy-a",
                  hostnames: ["worker-compute-ok"],
                  health_level: "ok"
                },
                {
                  storage_key: "storage-healthy-b",
                  hostnames: ["worker-home-ok"],
                  health_level: "ok"
                }
              ]
            },
            job: { id: 7, slug: "JOB-7", path: "/jobs/7" }
          }
        ],
        low_confidence_profiles: [],
        admission_overrides: []
      },
      chat_scoped_events: {
        window_hours: 24,
        total: 1,
        by_state: { completed: 1 },
        by_decision: { no_op: 0, respond: 1, act: 0 },
        failures: [],
        recent: [
          {
            id: 9,
            source_kind: "workflow_failed",
            summary: "Workflow failed",
            severity: "critical",
            delivery_state: "delivered",
            evaluator_state: "completed",
            decision: "respond",
            reason: "operator should know",
            created_at: "2026-06-05T11:01:00Z",
            chat: { id: 4, title: "Ops", path: "/chats/4" },
            repository: { id: 2, slug: "acme/widgets" },
            job: { id: 12, slug: "JOB-12", path: "/jobs/12" }
          }
        ]
      },
      workers: { total: 0, stale: 0 },
      worker_health: {
        generated_at: "2026-06-05T12:00:00Z",
        range: { since: "2026-06-04T12:00:00Z", until: "2026-06-05T12:00:00Z" },
        current_sample_window_seconds: 900,
        minute_bucket: { granularity_seconds: 60, window_minutes: 60, max_window_minutes: 1440 },
        current: [],
        hosts: []
      },
      recurring: { overdue: [] },
      stuck_pagination: { page: 1, per_page: 50, total: 0, total_pages: 1, first_item: 0, last_item: 0, previous_path: null, next_path: null },
      stuck: []
    }
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(payload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const first = render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/resource_admission"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Resource admission diagnostics" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Resource admission", level: 1 })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/app-shell/jobs/7?tab=workflows#workflow-12")
    expect(screen.getByText(/Localized worker pressure: storage-critical/)).toBeInTheDocument()
    expect(screen.getByText(/worker-compute-critical/)).toBeInTheDocument()
    expect(screen.getByText(/Healthy alternatives: storage-healthy-a/)).toBeInTheDocument()
    expect(screen.getByText(/storage-healthy-b/)).toBeInTheDocument()

    first.unmount()

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter initialEntries={["/app-shell/admin/scoped_chat_events"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Scoped chat event evaluator decisions" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Scoped chat events", level: 1 })).toBeInTheDocument()
    expect(screen.getByText("respond: 1")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-12" })).toHaveAttribute("href", "/app-shell/jobs/12")
  })

  it("renders the admin reconciler activity route", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/chats") {
        return Promise.resolve(new Response(JSON.stringify({ groups: [], repositories: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/admin/reconciler_activity")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              event_types: ["run_started", "issues_detected", "repair_executed", "run_finished"],
              filters: { event_type: null, job_id: null, workflow_id: null, run_id: null },
              pagination: { page: 1, per_page: 50, total: 1, total_pages: 1, first_item: 1, last_item: 1, previous_path: null, next_path: null },
              events: [
                {
                  id: 1,
                  event_type: "repair_executed",
                  severity: "info",
                  source: "spec",
                  message: "re-enqueued Run #42",
                  issue_kind: "queued_run_without_queue_claim",
                  repair_action: "reenqueue_run",
                  repair_status: "applied",
                  occurred_at: "2026-06-05T12:00:00Z",
                  details: { status: "applied" },
                  job: { id: 7, slug: "JOB-7", title: "Fix queue drift", path: "/jobs/7" },
                  workflow: { id: 12, slug: "WF-12", trigger_kind: "retry", state: "running", path: "/jobs/7?tab=workflows#workflow-12" },
                  run: { id: 42, state: "queued", path: "/admin/runs/42/transcript" }
                }
              ]
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/reconciler_activity"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("main", { name: "Reconciler events" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Reconciler events", level: 1 })).toBeInTheDocument()
    expect(await screen.findByText("re-enqueued Run #42")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-7" })).toHaveAttribute("href", "/app-shell/jobs/7")
    expect(screen.getByRole("link", { name: "WF-12" })).toHaveAttribute("href", "/app-shell/jobs/7?tab=workflows#workflow-12")
    expect(screen.getByRole("link", { name: "Run #42" })).toHaveAttribute("href", "/app-shell/admin/runs/42/transcript")
  })

  it("renders the migrated /admin route from the same admin overview component", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            active_runs: { total: 0, by_trigger: {} },
            queued_runs: { total: 0 },
            recent_failures_24h: { total: 0, by_trigger: {} },
            github_rate_limits: [],
            github_api_blocked_users: [],
            provider_circuits: [],
            agent_session_capture_rate: { total: 0, captured: 0, rate: null },
            data_root_disk_usage: null,
            resource_admission: {
              generated_at: "2026-06-05T12:00:00Z",
              windows: { recent_hours: 24, delayed_hours: 6 },
              active_consumers: [],
              recent_top_consumers: [],
              delayed_work: [],
              low_confidence_profiles: [],
              admission_overrides: []
            },
            chat_scoped_events: {
              window_hours: 24,
              total: 0,
              by_state: {},
              by_decision: { no_op: 0, respond: 0, act: 0 },
              failures: [],
              recent: []
            },
            workers: { total: 1, stale: 0 },
            recurring: { overdue: [] },
            stuck_pagination: { page: 1, per_page: 50, total: 0, total_pages: 1, first_item: 0, last_item: 0, previous_path: null, next_path: null },
            stuck: []
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/admin"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("GitHub rate limits")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Admin overview" })).toBeInTheDocument()
  })

  it("renders the spending insights route from the app API", async () => {
    const script = appendBootstrapScript()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      if (String(input) === "/api/v1/app/sidebar_pages") {
        return Promise.resolve(new Response(JSON.stringify(sidebarPluginPagesPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            scope: { admin: true, user_id: 1, label: "All users" },
            filters: {
              start_date: "2026-06-01",
              end_date: "2026-06-05",
              default_window_days: 90,
              agent_provider: null,
              agent_providers: [
                { value: "claude", label: "Claude Code" },
                { value: "codex", label: "Codex" }
              ]
            },
            filter: { and: [{ field: "created_at", op: "between", value: ["2026-06-01", "2026-06-05"] }] },
            controls: {
              filter_schema: [
                {
                  field: "created_at",
                  label: "Datetime",
                  bucket: "date",
                  operators: ["before", "after", "between", "within_last", "more_than_ago"],
                  values: [],
                  date_precision: "date"
                },
                {
                  field: "agent_provider",
                  label: "Agent",
                  bucket: "enum",
                  operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"],
                  values: [
                    { value: "claude", label: "Claude Code" },
                    { value: "codex", label: "Codex" }
                  ]
                },
                {
                  field: "repository_id",
                  label: "Repository",
                  bucket: "fk",
                  operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"],
                  typeahead: true
                },
                {
                  field: "user_id",
                  label: "User",
                  bucket: "fk",
                  operators: ["is", "is_not", "is_one_of", "is_none_of", "is_set", "is_unset"],
                  typeahead: true
                }
              ]
            },
            totals: {
              week_usd: 3.75,
              month_usd: 3.75,
              lifetime_usd: 4.5,
              workflow_lifetime_usd: 3.75,
              chat_lifetime_usd: 0.75,
              average_job_30d_usd: 1.875,
              average_merged_pr_30d_usd: 1.25
            },
            breakdowns: {
              epics: [{ id: 7, label: "Cost Senate", path: "/epics/7", jobs_count: 1, total_usd: 1.25, average_job_usd: 1.25, display_number: "EPIC-7" }],
              users: [
                { id: 2, label: "operator@example.com", path: "/profiles/2", jobs_count: 2, total_usd: 3.75, average_job_usd: 1.875, last_30_days_usd: 3.75 }
              ],
              repositories: [{ id: 3, label: "acme/syrus", path: "/repositories/3", jobs_count: 2, total_usd: 3.75, average_job_usd: 1.875 }],
              trigger_kinds: [{ trigger_kind: "initial", jobs_count: 2, runs_count: 2, total_usd: 3.75, average_usd: 1.875 }]
            },
            top_runs: [
              {
                id: 11,
                cost_usd: 2.5,
                trigger_kind: "initial",
                agent_provider: "codex",
                created_at: "2026-06-04T12:00:00Z",
                job: {
                  id: 9,
                  title: "Replace Meyer's-singleton statics with inline-variable constants across every remaining math header",
                  path: "/jobs/9?tab=workflows#workflow-4"
                },
                repository: { id: 3, slug: "tkadauke/raytracer", path: "/repositories/3" },
                epic: { id: 7, display_number: "EPIC-7", title: "Cost Senate", path: "/epics/7" }
              }
            ],
            trend: [
              { date: "2026-06-03", total_usd: 1.25 },
              { date: "2026-06-04", total_usd: 2.5 }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/insights/spending?start_date=2026-06-01&end_date=2026-06-05"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("This week")).toBeInTheDocument()
    expect(screen.getByRole("main", { name: "Spending insights" })).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/insights/spending?start_date=2026-06-01&end_date=2026-06-05",
      expect.objectContaining({ credentials: "same-origin" })
    )
    expect(screen.getByRole("link", { name: "EPIC-7 / Cost Senate" })).toHaveAttribute("href", "/app-shell/epics/7")
    const topRunJobLink = screen.getByRole("link", {
      name: "Replace Meyer's-singleton statics with inline-variable constants across every remaining math header"
    })
    expect(topRunJobLink).toHaveAttribute("href", "/app-shell/jobs/9?tab=workflows#workflow-4")
    expect(topRunJobLink).toHaveClass("block", "truncate")
    const repositoryLink = screen.getByRole("link", { name: "tkadauke/raytracer" })
    expect(repositoryLink).toHaveAttribute("href", "/app-shell/repositories/3")
    expect(repositoryLink).toHaveClass("block", "truncate")
    expect(screen.getByRole("img", { name: "Daily spend" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Datetime between 2026-06-01 - 2026-06-05/ })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /Add filter/ })).toBeInTheDocument()
    script.remove()
  })

  it("renders the admin stuck route from the app admin stuck API", async () => {
    const stuckPayload = {
      items: [
        {
          kind: "stale_heartbeat",
          severity: "warn",
          detail: "Run #4 silent for 10m",
          age_label: "10m",
          run_id: 4,
          workflow_id: 2,
          workflow_slug: "WF-2",
          workflow_path: "/jobs/1?tab=workflows#workflow-2",
          workflow_trigger_kind: "initial",
          step_kind: "implement",
          job_id: 1,
          job_state: "running",
          job_path: "/jobs/1",
          force_fail_path: "/api/v1/app/admin/jobs/1/force_fail",
          has_transcript: true
        }
      ],
      pagination: {
        page: 1,
        per_page: 50,
        total: 51,
        total_pages: 2,
        first_item: 1,
        last_item: 50,
        previous_path: null,
        next_path: "/admin/stuck?page=2"
      }
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/jobs/1/force_fail" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Job force-failed." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      return Promise.resolve(new Response(JSON.stringify(stuckPayload), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/stuck"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin stuck items" })).toBeInTheDocument()
    expect(screen.getByRole("heading", { name: "Stuck Things" }).closest("header")).toHaveClass("lg:items-end", "lg:justify-between")
    expect(screen.getByRole("button", { name: /Refresh/ })).toHaveClass("shrink-0")
    expect(await screen.findByText("Run #4 silent for 10m")).toBeInTheDocument()
    expect(screen.getByText("Showing 1-50 of 51")).toBeInTheDocument()
    expect(screen.getAllByRole("button", { name: "Next" })[0]).toBeEnabled()
    expect(screen.getByText("stale_heartbeat")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "WF-2" })).toHaveAttribute("href", "/app-shell/jobs/1?tab=workflows#workflow-2")
    expect(screen.getByRole("link", { name: "Job" })).toHaveAttribute("href", "/app-shell/jobs/1")
    expect(screen.getByRole("link", { name: "Transcript" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript")
    fireEvent.click(screen.getByRole("button", { name: "Force fail" }))
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/jobs/1/force_fail",
        expect.objectContaining({
          method: "POST",
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    })
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/stuck?page=1",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin console route from the app admin console API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            settings: {
              polling_paused: false,
              runs_paused: true,
              signups_open: true,
              max_job_failures: 3,
              grade_max_iterations: 2
            },
            users: [{ id: 1, email_address: "operator@example.com", display_name: "Operator" }],
            recent_admin_actions: [
              {
                id: 4,
                action: "pause_runs",
                performed_at: "2026-05-30T12:00:00Z",
                user_email: "operator@example.com",
                params: { source: "test" }
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/console"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin console" })).toBeInTheDocument()
    expect(screen.getByText("Operator Console")).toBeInTheDocument()
    expect(await screen.findByText("pause_runs")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Pause polling" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Resume runs" })).toBeInTheDocument()
    const reapButton = screen.getByRole("button", { name: "Reap now" })
    const reapPanel = screen.getByText("Reap stale Runs now").closest("section")
    expect(reapButton).toBeInTheDocument()
    expect(reapButton).toHaveClass("shrink-0")
    expect(reapPanel?.firstElementChild).toHaveClass("flex", "justify-between")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/console",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the admin installations route from the app admin installations API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            github_app_registered: true,
            github_app_slug: "operator-syrus",
            latest_sync: {
              last_attempted_at: null,
              last_successful_at: null,
              duration_ms: null,
              records_seen: null,
              error_class: null,
              error_message: null
            },
            pat_owner_groups: [
              {
                owner: "globex",
                repository_count: 1,
                install_url: "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&repository_ids[]=201"
              }
            ],
            repositories: [
              {
                id: 2,
                slug: "globex/pat-repo",
                owner: "globex",
                name: "pat-repo",
                owner_user: {
                  id: 9,
                  email_address: "operator@example.com",
                  admin: true
                },
                app_credential_active: false,
                app_credential_inactive_reason: "owner_mismatch_or_not_installed",
                recommended_next_action: "fallback_to_pat",
                credential_mode: "pat",
                account_login: "globex",
                installation_removed_at: null,
                github_owner_id: 101,
                github_repository_id: 201
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/installations"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin installations" })).toBeInTheDocument()
    expect(screen.getByText("GitHub App Installations")).toBeInTheDocument()
    expect(
      screen.getByText(
        "Syrus uses the GitHub App for repositories with an active installation. Repositories without one use the owner's personal access token fallback."
      )
    ).toBeInTheDocument()
    expect(await screen.findByText("globex/pat-repo")).toBeInTheDocument()
    expect(screen.getByText("operator@example.com")).toBeInTheDocument()
    expect(screen.getByText("Used when no active App installation exists")).toBeInTheDocument()
    expect(screen.getByText("No active installation")).toBeInTheDocument()
    expect(screen.getByText("Used as fallback")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Install on all PAT-only repos in this account" })).toHaveAttribute(
      "href",
      "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&repository_ids[]=201"
    )
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/installations",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the GitHub App registration route from the app admin API", async () => {
    const bounceUrl = "http://localhost:3000/admin/github_app/manifest?state=abc123&syrus_external=1"
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            github_app: {
              registered: true,
              id: 12345,
              slug: "operator-syrus",
              registered_at: "2026-05-30T12:00:00Z"
            },
            bounce_url: bounceUrl,
            submit_label: "Re-register GitHub App"
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/github_app/register"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const registration = screen.getByRole("main", { name: "GitHub App registration" })
    expect(registration).toBeInTheDocument()
    expect(
      within(registration).getByText(
        "Register the singleton Syrus GitHub App. Repositories use App credentials only after the App is installed on their GitHub account or repository."
      )
    ).toBeInTheDocument()
    expect(await within(registration).findByText("operator-syrus")).toBeInTheDocument()
    expect(
      within(registration).getByText(
        "GitHub will create the App from the manifest, then redirect back here with temporary credentials. Registration alone does not grant repository access; install the App after registration."
      )
    ).toBeInTheDocument()
    const openSpy = vi.spyOn(window, "open").mockReturnValue({} as Window)
    fireEvent.click(within(registration).getByRole("button", { name: "Re-register GitHub App" }))
    expect(openSpy).toHaveBeenCalledWith(bounceUrl, "_blank")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/github_app/register",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the GitHub App confirmation route from the app admin API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            github_app: {
              registered: true,
              id: 12345,
              slug: "operator-syrus",
              registered_at: "2026-05-30T12:00:00Z"
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/github_app/confirm"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const confirmation = screen.getByRole("main", { name: "GitHub App registered" })
    expect(confirmation).toBeInTheDocument()
    expect(await within(confirmation).findByText("operator-syrus")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/github_app/confirm",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("renders the invitations route from the app admin invitations API and revokes invitations", async () => {
    let revoked = false
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/invitations/9" && init?.method === "DELETE") {
        revoked = true
        return Promise.resolve(
          new Response(
            JSON.stringify({
              invitations: [],
              filter: { and: [] },
              filter_schema: [],
              filters: {},
              total: 0,
              pagination: {
                page: 1,
                per_page: 100,
                total: 0,
                total_pages: 1,
                has_previous_page: false,
                has_next_page: false,
                previous_page: null,
                next_page: null,
                first_item: 0,
                last_item: 0
              },
              sort: { column: "created_at", direction: "desc" },
              message: "Invitation revoked."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            invitations: revoked
              ? []
              : [
                  {
                    id: 9,
                    email_address: "guest@example.com",
                    token: "abc123",
                    share_url: "http://example.test/users/new?token=abc123",
                    expires_at: "2026-06-06T12:00:00Z",
                    created_at: "2026-05-30T12:00:00Z",
                    invited_by_email_address: "operator@example.com"
                  }
                ],
            filter: { and: [] },
            filter_schema: [],
            filters: {},
            total: revoked ? 0 : 1,
            pagination: {
              page: 1,
              per_page: 100,
              total: revoked ? 0 : 1,
              total_pages: 1,
              has_previous_page: false,
              has_next_page: false,
              previous_page: null,
              next_page: null,
              first_item: revoked ? 0 : 1,
              last_item: revoked ? 0 : 1
            },
            sort: { column: "created_at", direction: "desc" }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/invitations"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin invitations" })).toBeInTheDocument()
    expect(await screen.findByText("guest@example.com")).toBeInTheDocument()
    expect(screen.getByText("http://example.test/users/new?token=abc123")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Revoke" }))

    expect(await screen.findByText("Revoke this invitation?")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Yes, revoke" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Cancel" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Yes, revoke" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/invitations/9",
        expect.objectContaining({
          method: "DELETE",
          credentials: "same-origin",
          headers: { Accept: "application/json" }
        })
      )
    })
    expect(await screen.findByText("No pending invitations.")).toBeInTheDocument()
  })

  it("renders the app settings route from the app admin settings API and updates settings", async () => {
    const baseSettings = {
      signups_open: false,
      ui_engagement_telemetry_enabled: false,
      grade_max_iterations: 5,
      adversarial_review_rounds: 0,
      security_review_rounds: 0,
      max_job_failures: 3,
      merge_train_max_size: 20,
      main_concern_report_threshold: 2,
      report_issue_repo_slug: "tkadauke/syrus",
      video_retention_days: 7,
      video_storage_budget_mb: 2048,
      telegram_bot_handle: null,
      max_concurrent_agent_runs: 3,
      max_in_flight_workflows: 0,
      prepared_layer_cache_gb: 100,
      repository_full_poll_interval_hours: 24,
      proactive_rebase_commit_threshold: 20,
      show_work_unit_debug: false,
      rebase_failure_cooldown_minutes: 60,
      workflow_admission_control_enabled: true,
      workflow_admission_policy: "whole_workflow",
      workflow_admission_control_changed_at: null,
      workflow_admission_control_changed_by: null,
      chat_coding_workspace_budget_mb: 0,
      clearable_secrets: []
    }
    const submittedSettings = {
      signups_open: true,
      ui_engagement_telemetry_enabled: false,
      grade_max_iterations: 5,
      adversarial_review_rounds: 0,
      security_review_rounds: 0,
      max_job_failures: 3,
      merge_train_max_size: 20,
      main_concern_report_threshold: 2,
      report_issue_repo_slug: "tkadauke/syrus",
      video_retention_days: 7,
      video_storage_budget_mb: 2048,
      telegram_bot_handle: "",
      max_concurrent_agent_runs: 3,
      max_in_flight_workflows: 0,
      prepared_layer_cache_gb: 100,
      repository_full_poll_interval_hours: 24,
      proactive_rebase_commit_threshold: 20,
      show_work_unit_debug: false,
      rebase_failure_cooldown_minutes: 60,
      workflow_admission_control_enabled: true,
      workflow_admission_policy: "whole_workflow",
      chat_coding_workspace_budget_mb: 0
    }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/admin/settings" && init?.method === "PATCH") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              settings: { ...baseSettings, signups_open: true },
              message: "Settings updated."
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(
        new Response(
          JSON.stringify({
            settings: baseSettings
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/settings/edit"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin settings" })).toBeInTheDocument()
    await screen.findByRole("checkbox", { name: /Open signups/ })

    fireEvent.click(screen.getByRole("checkbox", { name: /Open signups/ }))
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/settings",
        expect.objectContaining({
          method: "PATCH",
          credentials: "same-origin",
          headers: expect.objectContaining({
            Accept: "application/json",
            "Content-Type": "application/json"
          }),
          body: JSON.stringify({
            app_setting: submittedSettings
          })
        })
      )
    })
    expect(await screen.findByText("Settings updated.")).toBeInTheDocument()
  })
})
