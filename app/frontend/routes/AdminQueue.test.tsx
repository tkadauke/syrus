import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { jsonResponse } from "../testSupport"
import { AdminQueueRoute } from "./AdminQueue"
import type { WorkerHealthPayload, WorkersQueuePayload } from "../api/adminQueue"

type WorkersQueuePayloadWithHealth = WorkersQueuePayload & { worker_health: WorkerHealthPayload }

function renderAdminQueue(initialEntry = "/admin/queue/workers") {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<AdminQueueRoute />} path="/admin/queue/:tab" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("AdminQueue worker health charts", () => {
  it("renders chart-first worker health with missing sample buckets", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayload()))

    renderAdminQueue()

    expect(await screen.findByRole("heading", { name: "Worker health" })).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-charts-worker-a")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-cpu_used_percent")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-load_1m")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-memory_used_percent")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-data_root_used_percent")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-cpu_pressure_some")).toBeInTheDocument()
    expect(screen.getByTestId("worker-health-chart-worker-a-io_pressure_some")).toBeInTheDocument()
    expect(screen.getAllByText("1 missing").length).toBeGreaterThan(0)
    expect(screen.getByText("Exact values")).toBeInTheDocument()
  })

  it("applies quick ranges through shareable query params", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayload()))

    renderAdminQueue()
    await screen.findByRole("heading", { name: "Worker health" })

    fireEvent.click(screen.getByRole("button", { name: "30m" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        expect.stringContaining("/api/v1/app/admin/queue/workers?"),
        expect.objectContaining({ credentials: "same-origin" })
      )
    })
    const requested = fetchSpy.mock.calls.map((call) => String(call[0])).find((url) => url.includes("minute_bucket_window_minutes=30"))
    expect(requested).toContain("since=")
    expect(requested).toContain("until=")
  })

  it("applies custom start and end params", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayload()))

    renderAdminQueue()
    const form = await screen.findByRole("form", { name: "Worker health range" })
    fireEvent.change(within(form).getByLabelText("Start"), { target: { value: "2026-05-30T09:00" } })
    fireEvent.change(within(form).getByLabelText("End"), { target: { value: "2026-05-30T11:00" } })
    fireEvent.click(within(form).getByRole("button", { name: "Apply" }))

    await waitFor(() => {
      expect(fetchSpy.mock.calls.some((call) => {
        const url = String(call[0])
        return url.includes("since=") &&
          url.includes("until=") &&
          url.includes("minute_bucket_window_minutes=120")
      })).toBe(true)
    })
  })

  it("keeps worker tables below the chart area on narrow layouts", async () => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: 390 })
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayload()))

    renderAdminQueue("/admin/queue/workers?since=2026-05-30T10%3A02%3A00.000Z&until=2026-05-30T12%3A02%3A00.000Z")

    expect(await screen.findByTestId("worker-health-charts-worker-a")).toBeInTheDocument()
    expect(screen.getByText("Queues")).toBeInTheDocument()
    expect(screen.getByText("Kind")).toBeInTheDocument()
  })

  it("labels health hosts without a current heartbeat as historical", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayload()))

    renderAdminQueue()

    expect(await screen.findByTestId("worker-health-charts-worker-a")).toBeInTheDocument()
    expect(screen.getByText("Historical workers (1)")).toBeInTheDocument()
    expect(screen.getByText("historical")).toBeInTheDocument()
    expect(screen.getByText("Historical samples in this range; host is not currently heartbeating.")).toBeInTheDocument()
  })

  it("shows active health hosts before collapsed historical hosts", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(workerQueuePayloadWithCurrentAndHistoricalHosts()))

    renderAdminQueue()

    const currentHost = await screen.findByText("worker-current")
    const historicalSummary = screen.getByText("Historical workers (1)")
    const historicalDetails = historicalSummary.closest("details")

    expect(currentHost.compareDocumentPosition(historicalSummary) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    expect(historicalDetails).not.toHaveAttribute("open")
    expect(screen.getByText("worker-historical")).not.toBeVisible()
  })

  it("hides the historical worker section when there are no historical hosts", async () => {
    const payload = workerQueuePayloadWithCurrentAndHistoricalHosts()
    payload.worker_health.hosts = payload.worker_health.hosts.filter((host) => host.status === "current")
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))

    renderAdminQueue()

    expect(await screen.findByText("worker-current")).toBeInTheDocument()
    expect(screen.queryByText(/Historical workers/)).not.toBeInTheDocument()
  })
})

function workerQueuePayload(): WorkersQueuePayloadWithHealth {
  return {
    workers: [
      {
        hostname: "worker-a",
        pid: 101,
        queues: "runs",
        threads: 2,
        last_heartbeat_at: "2026-05-30T12:00:00Z",
        stale: false,
        status: "current"
      }
    ],
    all_processes: [
      {
        kind: "Worker",
        hostname: "worker-a",
        pid: 101,
        last_heartbeat_at: "2026-05-30T12:00:00Z",
        stale: false,
        status: "current"
      }
    ],
    worker_health: {
      generated_at: "2026-05-30T12:02:00Z",
      range: {
        since: "2026-05-30T10:02:00Z",
        until: "2026-05-30T12:02:00Z"
      },
      current_sample_window_seconds: 900,
      minute_bucket: { granularity_seconds: 60, window_minutes: 3, max_window_minutes: 1440 },
      current: [
        {
          id: 4,
          hostname: "worker-a",
          role: "worker",
          version: "abc123",
          started_at: "2026-05-30T11:00:00Z",
          last_heartbeat_at: "2026-05-30T12:00:00Z",
          seconds_since_heartbeat: 120,
          stale: false,
          health: { level: "ok", reasons: [] },
          sample: workerSample("2026-05-30T12:01:00Z", 25, 1.2, 45, 55, 3, 4),
          trend: { sample_count: 1, first_observed_at: "2026-05-30T12:01:00Z", last_observed_at: "2026-05-30T12:01:00Z", warning_count: 0, critical_count: 0 }
        }
      ],
      hosts: [
        {
          hostname: "worker-a",
          status: "historical",
          current: null,
          windows: {
            "15m": summary(25, 1.2, 45, 55, 3, 4),
            "1h": summary(25, 1.2, 45, 55, 3, 4),
            "6h": summary(25, 1.2, 45, 55, 3, 4)
          },
          minute_buckets: [
            bucket("2026-05-30T12:00:00Z", 20, 1, 40, 50, 2, 3),
            { minute: "2026-05-30T12:01:00Z", sample_count: 0, first_observed_at: null, last_observed_at: null, warning_count: 0, critical_count: 0 },
            bucket("2026-05-30T12:02:00Z", 25, 1.2, 45, 55, 3, 4)
          ],
          recent_samples: [workerSample("2026-05-30T12:01:00Z", 25, 1.2, 45, 55, 3, 4)]
        }
      ]
    }
  }
}

function workerQueuePayloadWithCurrentAndHistoricalHosts() {
  const payload = workerQueuePayload()
  const currentWorker = payload.worker_health.current[0]
  const currentSample = workerSample("2026-05-30T12:01:00Z", 18, 0.8, 35, 45, 1, 2)

  payload.worker_health.current = [
    {
      ...currentWorker,
      hostname: "worker-current",
      sample: currentSample
    }
  ]
  payload.worker_health.hosts = [
    {
      ...payload.worker_health.hosts[0],
      hostname: "worker-historical",
      status: "historical",
      current: null,
      recent_samples: [workerSample("2026-05-30T11:30:00Z", 25, 1.2, 45, 55, 3, 4)]
    },
    {
      ...payload.worker_health.hosts[0],
      hostname: "worker-current",
      status: "current",
      current: payload.worker_health.current[0],
      recent_samples: [currentSample]
    }
  ]

  return payload
}

function workerSample(observedAt: string, cpu: number, load: number, memory: number, disk: number, cpuPressure: number, ioPressure: number) {
  return {
    id: 7,
    hostname: "worker-a",
    role: "worker",
    version: "abc123",
    observed_at: observedAt,
    cpu_used_percent: cpu,
    load_1m: load,
    load_5m: load,
    load_15m: load,
    memory_used_percent: memory,
    memory_available_bytes: 4294967296,
    memory_total_bytes: 8589934592,
    data_root_used_percent: disk,
    data_root_available_bytes: 10737418240,
    data_root_total_bytes: 21474836480,
    cpu_pressure_some: cpuPressure,
    cpu_pressure_full: null,
    io_pressure_some: ioPressure,
    io_pressure_full: null,
    raw_metrics: {}
  }
}

function bucket(minute: string, cpu: number, load: number, memory: number, disk: number, cpuPressure: number, ioPressure: number) {
  return {
    ...summary(cpu, load, memory, disk, cpuPressure, ioPressure),
    minute
  }
}

function summary(cpu: number, load: number, memory: number, disk: number, cpuPressure: number, ioPressure: number) {
  return {
    sample_count: 1,
    first_observed_at: "2026-05-30T12:01:00Z",
    last_observed_at: "2026-05-30T12:01:00Z",
    warning_count: 0,
    critical_count: 0,
    cpu_used_percent: { avg: cpu, max: cpu },
    load_1m: { avg: load, max: load },
    memory_used_percent: { avg: memory, max: memory },
    data_root_used_percent: { avg: disk, max: disk },
    cpu_pressure_some: { avg: cpuPressure, max: cpuPressure },
    io_pressure_some: { avg: ioPressure, max: ioPressure }
  }
}
