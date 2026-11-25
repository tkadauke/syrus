import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import i18n from "../i18n"
import { ProviderAvailabilityWarning, ProviderFailoverNotice, ProviderMismatchPill } from "./ProviderAvailabilityWarning"

describe("provider availability copy", () => {
  it("localizes warnings, failover notices, and mismatch ARIA while preserving provider labels", async () => {
    await i18n.changeLanguage("de")
    try {
      render(
        <>
          <ProviderAvailabilityWarning
            availability={{
              provider: "codex",
              label: "Codex",
              model: null,
              state: "available",
              open: false,
              usage_exhausted: false,
              retry_after: null,
              reason: null,
              message: "",
              pause_enabled: true,
              pause_threshold_percent: 20,
              usage: { remaining_percent: 12 }
            }}
          />
          <ProviderFailoverNotice
            failover={{
              mode: "automatic",
              automatic: true,
              original_provider: "claude",
              original_provider_label: "Claude",
              selected_provider: "codex",
              selected_provider_label: "Codex"
            }}
          />
          <ProviderMismatchPill
            mismatch={{
              job_provider: "codex",
              job_provider_label: "Codex",
              repository_provider: "claude",
              repository_provider_label: "Claude"
            }}
          />
        </>
      )

      expect(screen.getByRole("img")).toHaveAccessibleName("Die Nutzung von Codex ist niedrig (12 % verbleibend; Schwellenwert 20 %).")
      expect(screen.getByText("Claude ist nicht verfügbar; dieser Workflow läuft mit Codex.")).toBeInTheDocument()
      expect(screen.getByLabelText("Der Job läuft mit Codex; Repository-Standard ist Claude.")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("shows policy routing truthfully and exposes rule evidence through a touch-accessible disclosure", () => {
    render(
      <ProviderFailoverNotice
        failover={{
          mode: "policy_routing",
          automatic: false,
          original_provider: "codex",
          original_provider_label: "Codex",
          selected_provider: "claude",
          selected_provider_label: "Claude Code",
          routing: {
            matched_rule_id: 7,
            condition_results: {
              matched: true,
              conditions: {
                usage: {
                  matched: true,
                  expected: { provider: "codex", remaining_percent_less_than: 25 },
                  actual: { provider: "codex", remaining_percent: 22 }
                }
              }
            }
          }
        }}
      />
    )

    expect(screen.getByText("Routing policy selected Claude Code instead of Codex.")).toBeInTheDocument()
    expect(screen.queryByText(/Codex unavailable/)).not.toBeInTheDocument()
    const disclosure = screen.getByText("Details")
    expect(disclosure.closest("details")).not.toHaveAttribute("open")
    fireEvent.click(disclosure)
    expect(disclosure.closest("details")).toHaveAttribute("open")
    const details = screen.getByText(/Routing rule 7 matched/)
    expect(details).toBeVisible()
    expect(details).toHaveTextContent("Usage condition matched: Codex had 22% remaining; rule applies below 25%")
    expect(details).not.toHaveTextContent("Routing policy selected")
    expect(details).not.toHaveTextContent("remaining_percent")
    expect(details).not.toHaveTextContent("..")
  })
})
