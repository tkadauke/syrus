import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { PluginUiSlotCarousel, pluginUiSlotComponentFor, pluginUiSlotComponentKeys, type UiSlotPanel } from "./pluginUiSlots"

describe("pluginUiSlots", () => {
  it("returns null for an unknown component key", () => {
    expect(pluginUiSlotComponentFor("nope/Missing")).toBeNull()
    expect(pluginUiSlotComponentFor(null)).toBeNull()
    expect(pluginUiSlotComponentFor(undefined)).toBeNull()
  })

  it("exposes discovered plugin ui_slot component keys as plugin/Component", () => {
    expect(pluginUiSlotComponentKeys()).toContain("test_insights/JobTests")

    for (const key of pluginUiSlotComponentKeys()) {
      expect(key).toMatch(/^[^/]+\/[^/]+$/)
    }
  })

  it("does not resubscribe carousel panel visibility observers on ordinary rerenders", async () => {
    const originalMutationObserver = window.MutationObserver
    const observe = vi.fn()
    const disconnect = vi.fn()
    class FakeMutationObserver implements MutationObserver {
      constructor(_callback: MutationCallback) {}

      disconnect = disconnect
      observe = observe
      takeRecords = () => []
    }
    window.MutationObserver = FakeMutationObserver

    const labels = {
      region: "Dashboard notices",
      position: (index: number, count: number) => `${index} of ${count}`,
      previous: "Previous",
      next: "Next"
    }
    const panels: UiSlotPanel[] = [
      {
        id: "github_source.untagged_issues",
        component: "github_source/UntaggedIssuesBanner",
        order: 10,
        props: {
          untagged_issues: {
            total: 1,
            repositories: [
              { id: 1, slug: "acme/widgets", count: 1, issues_path: "/repositories/1/plugin/github/issues" }
            ]
          }
        }
      }
    ]

    try {
      const { rerender } = render(
        <MemoryRouter>
          <PluginUiSlotCarousel labels={labels} panels={panels} props={{ prefix: "" }} />
        </MemoryRouter>
      )

      expect(await screen.findByRole("status")).toHaveTextContent("1 unlabeled open issue")
      await waitFor(() => expect(observe).toHaveBeenCalled())

      observe.mockClear()
      rerender(
        <MemoryRouter>
          <PluginUiSlotCarousel labels={labels} panels={panels} props={{ prefix: "" }} />
        </MemoryRouter>
      )

      expect(observe).not.toHaveBeenCalled()
    } finally {
      window.MutationObserver = originalMutationObserver
    }
  })

  it("keeps a stable hook order when dashboard notice panels disappear", async () => {
    const labels = {
      region: "Dashboard notices",
      position: (index: number, count: number) => `${index} of ${count}`,
      previous: "Previous",
      next: "Next"
    }
    const panels: UiSlotPanel[] = [
      {
        id: "github_source.untagged_issues",
        component: "github_source/UntaggedIssuesBanner",
        order: 10,
        props: {
          untagged_issues: {
            total: 1,
            repositories: [
              { id: 1, slug: "acme/widgets", count: 1, issues_path: "/repositories/1/plugin/github/issues" }
            ]
          }
        }
      }
    ]

    const { rerender } = render(
      <MemoryRouter>
        <PluginUiSlotCarousel labels={labels} panels={panels} props={{ prefix: "" }} />
      </MemoryRouter>
    )

    expect(await screen.findByRole("status")).toHaveTextContent("1 unlabeled open issue")

    expect(() =>
      rerender(
        <MemoryRouter>
          <PluginUiSlotCarousel labels={labels} panels={[]} props={{ prefix: "" }} />
        </MemoryRouter>
      )
    ).not.toThrow()
  })
})
