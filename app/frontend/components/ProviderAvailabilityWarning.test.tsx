import { render, screen } from "@testing-library/react"
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
})
