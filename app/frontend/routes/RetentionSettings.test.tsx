import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach } from "vitest"

import { RetentionSettings } from "./RetentionSettings"

function retentionPayload(overrides: Record<string, unknown> = {}) {
  return {
    tables: [
      {
        key: "notification",
        table_name: "notifications",
        description: "In-app user notifications.",
        category: "Product",
        setting_key: "notification_retention_days",
        unit: "days",
        default_value: 30,
        retention_value: 30,
        row_count_estimate: 1000,
        byte_size_estimate: 204800,
        estimated_max_byte_size: 204800,
        computed_at: "2026-09-16T00:00:00Z",
        archivable: false,
        archive_setting_key: null,
        archive_before_delete: false
      }
    ],
    available_space: {
      available_bytes: 10 * 1024 ** 3,
      source: "measured",
      computed_at: "2026-09-16T00:00:00Z"
    },
    retention_available_space_override_gb: 0,
    storage_limits: {
      prepared_layer_cache_default_bytes: 10 * 1024 ** 3,
      coding_workspace_bytes: 10 * 1024 ** 3,
      prepared_layer_cache_workers: [
        {
          hostname: "worker-a",
          worker_storage_key: "storage-a",
          budget_bytes: 3 * 1024 ** 3,
          source: "worker_environment",
          observed_at: "2026-09-16T00:00:00Z"
        }
      ]
    },
    coworker_environment_recovery: {
      rollback_retention_count: 2,
      launch_failure_threshold: 3
    },
    runtime_environment: {
      policy: {
        builder: {
          max_concurrent_builds: 2,
          max_concurrent_per_namespace: 1,
          max_attempts: 3,
          cpus: 2,
          memory_bytes: 4294967296,
          pids: 512,
          storage_bytes: 10737418240,
          timeout_seconds: 1500,
          log_bytes: 5242880,
          max_output_bytes: 2147483648
        },
        supply_chain: { blocked_severities: ["critical", "high"], prohibited_packages: [] },
        base_promotion: { minimum_abi: 1, maximum_abi: 1 },
        recovery: { launch_failure_threshold: 3, rollback_retention_count: 2 },
        revocation: { terminate_running_turns_on_severe: true },
        worker_cache: { max_bytes: 21474836480, max_concurrent_pulls: 2, unused_retention_hours: 168 },
        scratch: { enabled: false, size_bytes: 1073741824 }
      },
      oci_registry: { configured: false, credentials: {} },
      build_network_rules: [],
      build_network_source_classes: [
        { key: "exact_domain", ecosystem_required: false, ecosystem_input_mode: "none", ecosystem_options: [], path_scoped: false, requirable: false },
        { key: "os_mirror", ecosystem_required: false, ecosystem_input_mode: "freeform", ecosystem_options: [], path_scoped: false, requirable: false },
        {
          key: "language_registry",
          ecosystem_required: true,
          ecosystem_input_mode: "select",
          ecosystem_options: ["npm", "pypi"],
          path_scoped: false,
          requirable: false
        },
        { key: "internal_mirror", ecosystem_required: false, ecosystem_input_mode: "freeform", ecosystem_options: [], path_scoped: false, requirable: true }
      ]
    },
    ...overrides
  }
}

function archivableTable(overrides: Record<string, unknown> = {}) {
  return {
    key: "run_diagnostic",
    table_name: "run_diagnostics",
    description: "Per-failed-Run diagnostic snapshots.",
    category: "Diagnostics",
    setting_key: "run_diagnostic_retention_days",
    unit: "days",
    default_value: 30,
    retention_value: 30,
    row_count_estimate: 500,
    byte_size_estimate: 102400,
    estimated_max_byte_size: 102400,
    computed_at: "2026-09-16T00:00:00Z",
    archivable: true,
    archive_setting_key: "run_diagnostic_archive_before_delete",
    archive_before_delete: false,
    ...overrides
  }
}

function retentionArchivesPayload(overrides: Record<string, unknown> = {}) {
  return {
    retention_key: "run_diagnostic",
    archives: [],
    pagination: { page: 1, per_page: 20, total: 0, total_pages: 0, first_item: 0, last_item: 0 },
    ...overrides
  }
}

function renderRoute() {
  if (!vi.isMockFunction(window.fetch)) {
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(retentionPayload())))
  }
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <RetentionSettings />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RetentionSettings", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders a row per table with current and estimated size", async () => {
    renderRoute()

    expect(await screen.findByText("notifications")).toBeInTheDocument()
    expect(screen.getByText("In-app user notifications.")).toBeInTheDocument()
    expect(screen.getByText("1,000 rows (200KB)")).toBeInTheDocument()
    expect(screen.getByText("Prepared workspace cache default")).toBeInTheDocument()
    expect(screen.getAllByText("10GB").length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText(/worker-a: 3GB/)).toBeInTheDocument()
    expect(screen.getByText(/worker environment override/)).toBeInTheDocument()
    expect(screen.getByText("Environment policy")).toBeInTheDocument()
    expect(screen.getByText("No runtime-image OCI registry is configured.")).toBeInTheDocument()
  })

  it("saves builder and supply-chain policy from the retention administration page", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "PATCH") return Promise.resolve(jsonResponse(retentionPayload({ message: "Retention settings updated." })))
      return Promise.resolve(jsonResponse(retentionPayload()))
    })
    renderRoute()
    await screen.findByText("Environment policy")

    fireEvent.change(screen.getByLabelText("Concurrent builds"), { target: { value: "4" } })
    fireEvent.change(screen.getByLabelText("Process limit per build"), { target: { value: "768" } })
    fireEvent.change(screen.getByLabelText("Prohibited packages (comma separated)"), { target: { value: "telnet, rsh" } })
    fireEvent.click(screen.getByRole("button", { name: "Save environment policy" }))

    await waitFor(() =>
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings",
        expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"max_concurrent_builds":4') })
      )
    )
    expect(fetchSpy.mock.calls.find(([, init]) => init?.method === "PATCH")?.[1]?.body).toContain('"prohibited_packages":["telnet","rsh"]')
    expect(fetchSpy.mock.calls.find(([, init]) => init?.method === "PATCH")?.[1]?.body).toContain('"pids":768')
  })

  it("creates a build-network rule from the environment policy card", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "POST") return Promise.resolve(jsonResponse(retentionPayload({ message: "Retention settings updated." })))
      return Promise.resolve(jsonResponse(retentionPayload()))
    })
    renderRoute()
    await screen.findByText("Build-network allowlist and mirrors")

    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "packages.example.test" } })
    fireEvent.click(screen.getByRole("button", { name: "Add rule" }))

    await waitFor(() =>
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings/network_rules",
        expect.objectContaining({ method: "POST", body: expect.stringContaining('"host":"packages.example.test"') })
      )
    )
  })

  it("creates OS and required internal mirrors for a free-form ecosystem", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "POST") return Promise.resolve(jsonResponse(retentionPayload({ message: "Retention settings updated." })))
      return Promise.resolve(jsonResponse(retentionPayload()))
    })
    renderRoute()
    await screen.findByText("Build-network allowlist and mirrors")

    fireEvent.change(screen.getByLabelText("Destination type"), { target: { value: "os_mirror" } })
    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "deb.example.test" } })
    fireEvent.change(screen.getByLabelText("Ecosystem"), { target: { value: "debian" } })
    fireEvent.click(screen.getByRole("button", { name: "Add rule" }))

    await waitFor(() => expect(fetchSpy.mock.calls.filter(([, init]) => init?.method === "POST")).toHaveLength(1))
    expect(fetchSpy.mock.calls.find(([, init]) => init?.method === "POST")?.[1]?.body).toContain(
      '"source_class":"os_mirror","host":"deb.example.test","port":443,"path_prefix":"","ecosystem":"debian"'
    )

    fireEvent.change(screen.getByLabelText("Destination type"), { target: { value: "internal_mirror" } })
    fireEvent.change(screen.getByLabelText("Host"), { target: { value: "apt.corp.example" } })
    fireEvent.change(screen.getByLabelText("Ecosystem"), { target: { value: "debian" } })
    fireEvent.click(screen.getByLabelText("Require this internal mirror"))
    fireEvent.click(screen.getByRole("button", { name: "Add rule" }))

    await waitFor(() => expect(fetchSpy.mock.calls.filter(([, init]) => init?.method === "POST")).toHaveLength(2))
    const secondBody = fetchSpy.mock.calls.filter(([, init]) => init?.method === "POST")[1][1]?.body
    expect(secondBody).toContain('"source_class":"internal_mirror"')
    expect(secondBody).toContain('"ecosystem":"debian","required":true')
  })

  it("shows disabled and scoped network-rule details and can delete a rule", async () => {
    const base = retentionPayload()
    const payload = retentionPayload({
      runtime_environment: {
        ...base.runtime_environment,
        build_network_rules: [
          {
            id: 7,
            source_class: "internal_mirror",
            host: "mirror.example.test",
            port: 8443,
            path_prefix: "",
            ecosystem: "npm",
            required: true,
            enabled: false,
            note: "private mirror"
          },
          {
            id: 8,
            source_class: "repository_namespace",
            host: "github.com",
            port: 443,
            path_prefix: "/acme/",
            ecosystem: "",
            required: false,
            enabled: true,
            note: "source namespace"
          }
        ]
      }
    })
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (init?.method === "DELETE") return Promise.resolve(jsonResponse(retentionPayload()))
      return Promise.resolve(jsonResponse(payload))
    })
    renderRoute()

    expect(await screen.findByText(/mirror\.example\.test:8443/)).toBeInTheDocument()
    expect(screen.getByText(/github\.com:443\/acme\//)).toBeInTheDocument()
    expect(screen.getByText("disabled")).toBeInTheDocument()
    expect(screen.getByText("ecosystem: npm")).toBeInTheDocument()
    fireEvent.click(screen.getAllByRole("button", { name: "Delete" })[0])
    await waitFor(() =>
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/retention_settings/network_rules/7", expect.objectContaining({ method: "DELETE" }))
    )
  })

  it("sets a table to infinite retention and saves 0", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(
          jsonResponse(
            retentionPayload({
              message: "Retention settings updated.",
              tables: [{ ...retentionPayload().tables[0], retention_value: 0, estimated_max_byte_size: null }]
            })
          )
        )
      }
      return Promise.resolve(jsonResponse(retentionPayload()))
    })

    renderRoute()
    await screen.findByText("notifications")

    fireEvent.click(screen.getByLabelText("Infinite retention"))
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[1])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ retention_settings: { notification_retention_days: 0, notification_retention_days_infinite: true } })
        })
      )
    })
    expect(await screen.findByText("Unbounded")).toBeInTheDocument()
  })

  it("sets a previously-infinite table back to a finite value", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(
          jsonResponse(
            retentionPayload({
              message: "Retention settings updated.",
              tables: [{ ...retentionPayload().tables[0], retention_value: 45, estimated_max_byte_size: 300000 }]
            })
          )
        )
      }
      return Promise.resolve(
        jsonResponse(
          retentionPayload({
            tables: [{ ...retentionPayload().tables[0], retention_value: 0, estimated_max_byte_size: null }]
          })
        )
      )
    })

    renderRoute()
    await screen.findByText("notifications")

    const infiniteCheckbox = screen.getByLabelText("Infinite retention") as HTMLInputElement
    expect(infiniteCheckbox.checked).toBe(true)

    fireEvent.click(infiniteCheckbox)
    const numberInput = screen.getByDisplayValue("30")
    fireEvent.change(numberInput, { target: { value: "45" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[1])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ retention_settings: { notification_retention_days: 45, notification_retention_days_infinite: false } })
        })
      )
    })
  })

  it("blocks a blank finite retention value before it can be saved as infinite", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse(retentionPayload())))

    renderRoute()
    await screen.findByText("notifications")

    const numberInput = screen.getByLabelText("Retention window for notifications")
    fireEvent.change(numberInput, { target: { value: "" } })
    fireEvent.submit(numberInput.closest("form")!)

    expect(await screen.findByRole("alert")).toHaveTextContent("Enter a retention window of at least 1.")
    expect(fetchSpy).not.toHaveBeenCalledWith(
      "/api/v1/app/admin/retention_settings",
      expect.objectContaining({
        method: "PATCH"
      })
    )
  })

  it("does not save a blank finite retention value as infinite", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(retentionPayload()))

    renderRoute()
    await screen.findByText("notifications")

    const input = screen.getByLabelText("Retention window for notifications")
    fireEvent.change(input, { target: { value: "" } })

    const saveButton = screen.getAllByRole("button", { name: "Save" })[1]
    expect(saveButton).toBeDisabled()
    const form = input.closest("form")
    if (!form) throw new Error("Retention settings form not found")
    fireEvent.submit(form)
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/admin/retention_settings", expect.objectContaining({ method: "PATCH" }))
  })

  it("saves the manual available-space override", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(
          jsonResponse(
            retentionPayload({
              message: "Retention settings updated.",
              retention_available_space_override_gb: 500,
              available_space: { available_bytes: 500 * 1024 ** 3, source: "manual", computed_at: "2026-09-16T00:00:00Z" }
            })
          )
        )
      }
      return Promise.resolve(jsonResponse(retentionPayload()))
    })

    renderRoute()
    await screen.findByText("notifications")

    const overrideInput = screen.getByLabelText("Manual available space override (GB)")
    fireEvent.change(overrideInput, { target: { value: "500" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[0])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({ retention_settings: { retention_available_space_override_gb: 500 } })
        })
      )
    })
  })

  it("toggles archive-before-delete for an archivable table and shows the resulting archive with a working download link", async () => {
    const table = archivableTable()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const url = String(input)
      if (url === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(
          jsonResponse(
            retentionPayload({
              message: "Retention settings updated.",
              tables: [{ ...table, archive_before_delete: true }]
            })
          )
        )
      }
      if (url.startsWith("/api/v1/app/admin/retention_archives")) {
        return Promise.resolve(
          jsonResponse(
            retentionArchivesPayload({
              archives: [
                {
                  id: 1,
                  pruned_before: "2026-08-01T00:00:00Z",
                  row_count: 42,
                  byte_size: 2048,
                  created_at: "2026-08-02T00:00:00Z",
                  filename: "run_diagnostic-20260802000000.jsonl.gz",
                  download_path: "/api/v1/app/admin/retention_archives/1/download"
                }
              ],
              pagination: { page: 1, per_page: 20, total: 1, total_pages: 1, first_item: 1, last_item: 1 }
            })
          )
        )
      }
      return Promise.resolve(jsonResponse(retentionPayload({ tables: [table] })))
    })

    renderRoute()
    await screen.findByText("run_diagnostics")

    fireEvent.click(screen.getByLabelText("Archive before delete"))
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[1])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/admin/retention_settings",
        expect.objectContaining({
          method: "PATCH",
          body: JSON.stringify({
            retention_settings: {
              run_diagnostic_retention_days: 30,
              run_diagnostic_retention_days_infinite: false,
              run_diagnostic_archive_before_delete: true
            }
          })
        })
      )
    })

    fireEvent.click(screen.getByRole("button", { name: "View archives" }))

    const downloadLink = await screen.findByRole("link", { name: "Download" })
    expect(downloadLink).toHaveAttribute("href", "/api/v1/app/admin/retention_archives/1/download")
  })

  it("does not show a view-archives toggle for a non-archivable table", async () => {
    renderRoute()

    await screen.findByText("notifications")

    expect(screen.queryByRole("button", { name: "View archives" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Archive before delete")).not.toBeInTheDocument()
  })
})
