import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { DashboardPayload, DashboardEpicItem, DashboardJobItem } from "../api/dashboard"
import { DashboardTable, LegacyEpicsBanner } from "./Dashboard"

describe("Dashboard simple mode", () => {
  it("renders every Job with its own status shown directly, not an epic rollup", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Checkout polish")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("Ship the invoice PDF export")).toBeInTheDocument()
    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getByText("Pr merged")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /checkout polish/i })).not.toBeInTheDocument()
    expect(screen.queryByText("Workflow")).not.toBeInTheDocument()
  })

  it("renders the legacy epic list unchanged when subject is epic, instead of the job list", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <DashboardTable payload={simpleEpicsDashboardPayload()} prefix="" setupStatus={null as never} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const link = screen.getByRole("link", { name: /legacy checkout revamp/i })
    expect(link).toHaveAttribute("href", "/epics/9")
    expect(screen.queryByText("Ship the invoice PDF export")).not.toBeInTheDocument()
  })
})

describe("LegacyEpicsBanner", () => {
  it("explains that these are older features and new requests appear on the main dashboard", () => {
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <LegacyEpicsBanner />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("status")).toHaveTextContent(/older, multi-step features/i)
    expect(screen.getByRole("status")).toHaveTextContent(/individual tasks on the main dashboard/i)
  })
})

  }
}
