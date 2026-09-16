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
        computed_at: "2026-09-16T00:00:00Z"
      }
    ],
    available_space: {
      available_bytes: 10 * 1024 ** 3,
      source: "measured",
      computed_at: "2026-09-16T00:00:00Z"
    },
    retention_available_space_override_gb: 0,
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
  })

  it("sets a table to infinite retention and saves 0", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(retentionPayload({
          message: "Retention settings updated.",
          tables: [{ ...retentionPayload().tables[0], retention_value: 0, estimated_max_byte_size: null }]
        })))
      }
      return Promise.resolve(jsonResponse(retentionPayload()))
    })

    renderRoute()
    await screen.findByText("notifications")

    fireEvent.click(screen.getByLabelText("Infinite retention"))
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[1])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/retention_settings", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ retention_settings: { notification_retention_days: 0 } })
      }))
    })
    expect(await screen.findByText("Unbounded")).toBeInTheDocument()
  })

  it("sets a previously-infinite table back to a finite value", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(retentionPayload({
          message: "Retention settings updated.",
          tables: [{ ...retentionPayload().tables[0], retention_value: 45, estimated_max_byte_size: 300000 }]
        })))
      }
      return Promise.resolve(jsonResponse(retentionPayload({
        tables: [{ ...retentionPayload().tables[0], retention_value: 0, estimated_max_byte_size: null }]
      })))
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
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/retention_settings", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ retention_settings: { notification_retention_days: 45 } })
      }))
    })
  })

  it("saves the manual available-space override", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      if (String(input) === "/api/v1/app/admin/retention_settings" && init?.method === "PATCH") {
        return Promise.resolve(jsonResponse(retentionPayload({
          message: "Retention settings updated.",
          retention_available_space_override_gb: 500,
          available_space: { available_bytes: 500 * 1024 ** 3, source: "manual", computed_at: "2026-09-16T00:00:00Z" }
        })))
      }
      return Promise.resolve(jsonResponse(retentionPayload()))
    })

    renderRoute()
    await screen.findByText("notifications")

    const overrideInput = screen.getByLabelText("Manual available space override (GB)")
    fireEvent.change(overrideInput, { target: { value: "500" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Save" })[0])

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/admin/retention_settings", expect.objectContaining({
        method: "PATCH",
        body: JSON.stringify({ retention_settings: { retention_available_space_override_gb: 500 } })
      }))
    })
  })
})
