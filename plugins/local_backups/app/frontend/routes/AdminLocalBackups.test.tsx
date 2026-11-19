import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { jsonResponse } from "@app/testSupport"
import { describe, expect, it, vi } from "vitest"
import AdminLocalBackups from "./AdminLocalBackups"

describe("AdminLocalBackups", () => {
  it("renders discovered sealed backups without mutation controls", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      configured: true,
      root: "/safe/backups",
      invalid_artifacts: [],
      backups: [{ uuid: "123e4567-e89b-42d3-a456-426614174000", state: "completed", artifact_path: "bundle", manifest_version: 1, database_adapter: "sqlite3", logical_bytes: 10, stored_bytes: 8, blob_count: 1, checksum_algorithm: "sha256", checksum: "a".repeat(64), verification_state: "valid", source_application_version: "1.0", completed_at: "2026-11-19T00:00:00Z", validated_at: "2026-11-19T00:01:00Z" }]
    }))
    render(<QueryClientProvider client={new QueryClient()}><AdminLocalBackups /></QueryClientProvider>)

    expect(await screen.findByText("123e4567-e89b-42d3-a456-426614174000")).toBeInTheDocument()
    expect(screen.getByText("sqlite3")).toBeInTheDocument()
    expect(screen.queryByRole("button")).not.toBeInTheDocument()
  })
})
