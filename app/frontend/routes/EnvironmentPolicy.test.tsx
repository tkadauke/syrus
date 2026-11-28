import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { jsonResponse } from "../testSupport"
import { EnvironmentPolicy } from "./EnvironmentPolicy"

const payload = {
  policy: {
    builder: { max_concurrent_builds: 2 },
    verification: { blocked_severities: ["critical", "high"], prohibited_packages: [] },
    scratch: { profile: "standard", size: "1g" }
  },
  registry: { configured: true, url: "https://registry.example", repository_prefix: "syrus" },
  network_rules_path: "/api/v1/admin/runtime_image_build_network_rules"
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(<QueryClientProvider client={client}><EnvironmentPolicy /></QueryClientProvider>)
}

describe("EnvironmentPolicy", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows safe registry status and saves the edited policy", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((_input, init) => Promise.resolve(
      jsonResponse(init?.method === "PATCH" ? { ...payload, message: "Environment policy updated." } : payload)
    ))
    renderPage()

    expect(await screen.findByText("https://registry.example/syrus")).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText("Environment policy JSON"), { target: { value: JSON.stringify(payload.policy) } })
    fireEvent.click(screen.getByRole("button", { name: "Save policy" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledTimes(2))
    expect(await screen.findByText("Environment policy updated.")).toBeInTheDocument()
    expect(String(fetchSpy.mock.calls[1][0])).toBe("/api/v1/app/admin/environment_policy")
  })
})
