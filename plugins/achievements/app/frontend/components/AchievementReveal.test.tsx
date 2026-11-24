import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "@app/i18n"
import type { AchievementUnlock } from "../api/achievements"
import { AchievementRevealQueue, sortReveals } from "./AchievementReveal"

function unlock(id: number, overrides: Partial<AchievementUnlock> = {}): AchievementUnlock {
  return {
    id,
    key: "example.first_job_landed",
    version: 1,
    scope: "user",
    category: "landing",
    rarity: "common",
    visibility: "visible",
    presentation: { title_key: "achievements:example.first_job_landed.title", description_key: "achievements:example.first_job_landed.description" },
    unlocked_at: `2026-11-24T10:00:0${id}Z`,
    acknowledged: false,
    acknowledged_at: null,
    ...overrides
  }
}

function setVisibility(state: "visible" | "hidden") {
  Object.defineProperty(document, "visibilityState", { configurable: true, get: () => state })
  document.dispatchEvent(new Event("visibilitychange"))
}

afterEach(async () => {
  Reflect.deleteProperty(window, "matchMedia")
  setVisibility("visible")
  vi.restoreAllMocks()
  await i18n.changeLanguage("en")
})

describe("AchievementRevealQueue", () => {
  it("orders reveals deterministically by unlock time then id", () => {
    const ordered = sortReveals([unlock(3, { unlocked_at: "2026-11-24T10:00:01Z" }), unlock(2, { unlocked_at: "2026-11-24T10:00:01Z" }), unlock(1, { unlocked_at: "2026-11-24T11:00:00Z" })])
    expect(ordered.map((entry) => entry.id)).toEqual([2, 3, 1])
  })

  it("presents an accessible dialog and acknowledges only after presenting, one at a time", async () => {
    const acknowledge = vi.fn().mockResolvedValue(undefined)
    render(<AchievementRevealQueue acknowledge={acknowledge} reveals={[unlock(2), unlock(1)]} />)

    const dialog = await screen.findByRole("dialog")
    expect(dialog).toHaveAttribute("aria-modal", "true")
    expect(screen.getByRole("heading", { name: "First Job landed" })).toBeInTheDocument()
    expect(screen.getByText("1 of 2")).toBeInTheDocument()
    expect(dialog.querySelector("audio, video")).toBeNull()
    await waitFor(() => expect(acknowledge).toHaveBeenCalledTimes(1))
    expect(acknowledge.mock.calls[0][0].id).toBe(1)

    fireEvent.click(screen.getByRole("button", { name: "Next" }))
    expect(await screen.findByText("2 of 2")).toBeInTheDocument()
    await waitFor(() => expect(acknowledge).toHaveBeenCalledTimes(2))
    expect(acknowledge.mock.calls[1][0].id).toBe(2)

    fireEvent.click(screen.getByRole("button", { name: "Continue" }))
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull())
    expect(acknowledge).toHaveBeenCalledTimes(2)
  })

  it("does not acknowledge while the tab is hidden, then does once visible", async () => {
    setVisibility("hidden")
    const acknowledge = vi.fn().mockResolvedValue(undefined)
    render(<AchievementRevealQueue acknowledge={acknowledge} reveals={[unlock(1)]} />)

    await screen.findByRole("dialog")
    expect(acknowledge).not.toHaveBeenCalled()

    act(() => setVisibility("visible"))
    await waitFor(() => expect(acknowledge).toHaveBeenCalledTimes(1))
  })

  it("does not acknowledge a reveal that unmounts before presentation", () => {
    setVisibility("hidden")
    const acknowledge = vi.fn().mockResolvedValue(undefined)
    const { unmount } = render(<AchievementRevealQueue acknowledge={acknowledge} reveals={[unlock(1)]} />)
    unmount()
    act(() => setVisibility("visible"))
    expect(acknowledge).not.toHaveBeenCalled()
  })

  it("offers a retry when acknowledging fails and does not trap the user", async () => {
    const acknowledge = vi.fn().mockRejectedValueOnce(new Error("offline")).mockResolvedValue(undefined)
    render(<AchievementRevealQueue acknowledge={acknowledge} reveals={[unlock(1)]} />)

    expect(await screen.findByRole("alert")).toHaveTextContent("Could not save that you saw this.")
    fireEvent.click(screen.getByRole("button", { name: "Retry" }))
    await waitFor(() => expect(acknowledge).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.queryByRole("alert")).toBeNull())
  })

  it("lets Escape dismiss the reveal and reports when the queue is finished", async () => {
    const onFinished = vi.fn()
    render(<AchievementRevealQueue acknowledge={vi.fn().mockResolvedValue(undefined)} onFinished={onFinished} reveals={[unlock(1)]} />)

    await screen.findByRole("dialog")
    fireEvent.keyDown(document, { key: "Escape" })
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull())
    expect(onFinished).toHaveBeenCalledTimes(1)
  })

  it("marks reduced motion and skips the entrance transition", async () => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      writable: true,
      value: (query: string) => ({ matches: query.includes("reduce"), media: query, addEventListener: vi.fn(), removeEventListener: vi.fn() })
    })
    render(<AchievementRevealQueue acknowledge={vi.fn().mockResolvedValue(undefined)} reveals={[unlock(1)]} />)

    const dialog = await screen.findByRole("dialog")
    expect(screen.getByTestId("achievement-reveal")).toHaveAttribute("data-reduced-motion", "true")
    expect(dialog.className).not.toContain("transition")
  })
})
