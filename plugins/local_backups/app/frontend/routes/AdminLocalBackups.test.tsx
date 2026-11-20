import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "@app/testSupport"
import AdminLocalBackups from "./AdminLocalBackups"

describe("AdminLocalBackups", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders sealed inventory controls", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse({
        root: { configured: true, path: "/srv/backups" },
        scan: { discovered: 1, invalid: [] },
        backups: [
          {
            uuid: "backup-1",
            reason: "manual",
            database_adapter: "sqlite3",
            logical_bytes: 20,
            stored_bytes: 10,
            blob_count: 2,
            completed_at: "2026-11-19T00:00:00Z",
            validated_at: null,
            verification_state: "valid",
            source_application_version: "1.2.3",
            artifact_checksum: "abc",
            checksum_algorithm: "sha256",
            encryption_key_fingerprint: "sha256:def",
            pinned: false,
            state: "completed"
          }
        ]
      })
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <AdminLocalBackups />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("/srv/backups")).toBeInTheDocument()
    expect(screen.getByText("sqlite3")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Create backup" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Validate" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Pin" })).toBeInTheDocument()
  })
})
