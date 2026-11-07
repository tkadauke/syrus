import { renderHook, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { useBrowserTimeZone } from "./useBrowserTimeZone"

afterEach(() => vi.restoreAllMocks())

function payload(mode: "automatic" | "manual", name = "Etc/UTC") {
  return { time_zones: { user: { mode, name } } } as BootstrapPayload
}

describe("useBrowserTimeZone", () => {
  it("ignores bootstrap payloads without time-zone data", () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")

    renderHook(() => useBrowserTimeZone({} as BootstrapPayload))

    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it("reports a changed browser zone for automatic users", async () => {
    vi.spyOn(Intl, "DateTimeFormat").mockReturnValue({ resolvedOptions: () => ({ timeZone: "Europe/Berlin" }) } as Intl.DateTimeFormat)
    const fetchSpy = vi
      .spyOn(globalThis, "fetch")
      .mockResolvedValue(
        new Response(JSON.stringify({ time_zone: "Europe/Berlin", mode: "automatic" }), { status: 200, headers: { "Content-Type": "application/json" } })
      )

    renderHook(() => useBrowserTimeZone(payload("automatic")))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalled())
    expect(fetchSpy.mock.calls[0]?.[0]).toBe("/api/v1/app/user_time_zone")
  })

  it("keeps manual overrides fixed", () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch")

    renderHook(() => useBrowserTimeZone(payload("manual", "America/New_York")))

    expect(fetchSpy).not.toHaveBeenCalled()
  })
})
