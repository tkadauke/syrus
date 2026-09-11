import { renderHook, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { useDebouncedProbe } from "./useDebouncedProbe"
import type { CredentialTestResult } from "../api/credentials"

const okResult: CredentialTestResult = { credential: "github_token", ok: true, message: "Token is valid.", details: {} }

// Short debounce keeps the suite fast while still exercising the timer path.
const OPTIONS = { delayMs: 10, errorFallback: "Could not verify." }

describe("useDebouncedProbe", () => {
  it("stays idle for an empty value and never calls the probe", async () => {
    const probe = vi.fn()
    const { result } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "   " }
    })

    expect(result.current).toEqual({ status: "idle" })
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(probe).not.toHaveBeenCalled()
  })

  it("debounces: reports testing immediately, then done with the probe result", async () => {
    const probe = vi.fn().mockResolvedValue(okResult)
    const { result } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "ghp_token" }
    })

    expect(result.current).toEqual({ status: "testing" })
    await waitFor(() => expect(result.current).toEqual({ status: "done", result: okResult }))
    expect(probe).toHaveBeenCalledTimes(1)
    expect(probe).toHaveBeenCalledWith("ghp_token")
  })

  it("trims the value before probing", async () => {
    const probe = vi.fn().mockResolvedValue(okResult)
    const { result } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "  ghp_token  " }
    })

    await waitFor(() => expect(result.current.status).toBe("done"))
    expect(probe).toHaveBeenCalledWith("ghp_token")
  })

  it("drops a stale in-flight result when the value changes (staleness guard)", async () => {
    const staleResult: CredentialTestResult = { credential: "github_token", ok: false, message: "Stale token.", details: {} }
    let resolveFirst: (result: CredentialTestResult) => void = () => {}
    const probe = vi
      .fn()
      .mockImplementationOnce(
        () =>
          new Promise<CredentialTestResult>((resolve) => {
            resolveFirst = resolve
          })
      )
      .mockResolvedValueOnce(okResult)

    const { result, rerender } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "ghp_first" }
    })

    // Let the first probe fire, then supersede it before it resolves.
    await waitFor(() => expect(probe).toHaveBeenCalledTimes(1))
    rerender({ value: "ghp_second" })
    await waitFor(() => expect(probe).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(result.current).toEqual({ status: "done", result: okResult }))

    // The stale first response lands late — it must NOT overwrite the newer state.
    resolveFirst(staleResult)
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(result.current).toEqual({ status: "done", result: okResult })
  })

  it("stays idle when the value is cleared while a probe is in flight", async () => {
    let resolveProbe: (result: CredentialTestResult) => void = () => {}
    const probe = vi.fn(
      () =>
        new Promise<CredentialTestResult>((resolve) => {
          resolveProbe = resolve
        })
    )
    const { result, rerender } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "ghp_token" }
    })

    // Let the probe fire, then clear the input before it resolves.
    await waitFor(() => expect(probe).toHaveBeenCalledTimes(1))
    rerender({ value: "" })
    expect(result.current).toEqual({ status: "idle" })

    // The stale response lands late — it must NOT resurrect a green result
    // over the emptied input (which would re-enable Save with nothing typed).
    resolveProbe(okResult)
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(result.current).toEqual({ status: "idle" })
  })

  it("resets to idle when the value is cleared", async () => {
    const probe = vi.fn().mockResolvedValue(okResult)
    const { result, rerender } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "ghp_token" }
    })

    await waitFor(() => expect(result.current.status).toBe("done"))
    rerender({ value: "" })
    expect(result.current).toEqual({ status: "idle" })
  })

  it("reports the thrown error message, falling back for non-Error throws", async () => {
    const probe = vi.fn().mockRejectedValue(new Error("GitHub is unreachable."))
    const { result, rerender } = renderHook(({ value }) => useDebouncedProbe(value, probe, OPTIONS), {
      initialProps: { value: "ghp_token" }
    })

    await waitFor(() => expect(result.current).toEqual({ status: "error", message: "GitHub is unreachable." }))

    probe.mockRejectedValue("boom")
    rerender({ value: "ghp_other" })
    await waitFor(() => expect(result.current).toEqual({ status: "error", message: "Could not verify." }))
  })
})
