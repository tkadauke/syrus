import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { RuntimeEnvironmentSettings } from "./RuntimeEnvironmentSettings"

const payload = {
  registry: { url: "https://registry.example.test", repository_prefix: "syrus", credentials: { builder: { username: "build", password_set: true }, worker: { username: "pull", password_set: true }, admin: { username: "admin", password_set: false } } },
  policy: {
    builder: { max_concurrent_builds: 2, max_concurrent_per_namespace: 1, cpus: 2, memory_bytes: 4096, storage_bytes: 8192, timeout_seconds: 1500, log_bytes: 1024 },
    verification: { blocked_severities: ["critical", "high"], prohibited_packages: ["unsafe-package"] },
    base: { promotion_requires_compatible_abi: true, rollback_retention_days: 90 }, revocation: { terminate_running_on_severe: true },
    cache: { max_concurrent_pulls: 2, pull_timeout_seconds: 600, high_pressure_percent: 80, critical_pressure_percent: 92, prefetch_active: false },
    runtime: { mount_profile: "standard", scratch_size: "1g" }
  },
  network_rules: [{ id: 1, source_class: "internal_mirror", host: "mirror.example.test", port: null, path_prefix: null, ecosystem: null, required: true, enabled: true, note: null }],
  source_classes: ["internal_mirror", "source_host"], language_ecosystems: []
}

describe("RuntimeEnvironmentSettings", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders registry, policy, mirror, cache, and scratch controls without secret values", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(payload))
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><MemoryRouter><RuntimeEnvironmentSettings /></MemoryRouter></QueryClientProvider>)

    expect(screen.getByRole("heading", { name: "Environment Policy" })).toBeInTheDocument()
    expect(await screen.findByDisplayValue("https://registry.example.test")).toBeInTheDocument()
    expect(screen.getByText(/mirror.example.test/)).toBeInTheDocument()
    expect(screen.getByLabelText("builder password")).toHaveValue("")
    expect(screen.getByLabelText("Mount profile")).toHaveValue("standard")
  })
})
