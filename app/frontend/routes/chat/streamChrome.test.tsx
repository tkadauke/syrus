import { render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { ChatTurnRetryState } from "../../api/chats"
import { TurnRetryIndicator } from "./streamChrome"

function retryState(overrides: Partial<ChatTurnRetryState> = {}): ChatTurnRetryState {
  return {
    classification: "chat_turn_crashed",
    classification_label: "Chat turn crashed",
    retryable: true,
    next_auto_retry_at: "2026-09-18T12:05:00Z",
    retry_attempt_count: 2,
    retry_budget_remaining: 1,
    retry_budget: 3,
    auto_retry_exhausted: false,
    provider_circuit_open: false,
    retry_delayed_until: null,
    retry_delay_reason: null,
    state_label: "Retry scheduled",
    ...overrides
  }
}

describe("TurnRetryIndicator", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("renders the scheduled retry countdown and retry budget", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-09-18T12:00:00Z"))

    render(<TurnRetryIndicator retry={retryState()} />)

    expect(screen.getByRole("status", { name: /Chat turn crashed .* retryable .* 1 left .* next in 5 minutes/ })).toBeInTheDocument()
    expect(screen.getByText("Retry scheduled")).toBeInTheDocument()
    expect(screen.getByText("attempt 2/3")).toBeInTheDocument()
    expect(screen.getByText("next in 5 minutes")).toBeInTheDocument()
  })

  it("renders an exhausted retry budget without a countdown", () => {
    render(<TurnRetryIndicator retry={retryState({
      retryable: false,
      next_auto_retry_at: null,
      retry_attempt_count: 3,
      retry_budget_remaining: 0,
      auto_retry_exhausted: true,
      state_label: "Auto-retry exhausted"
    })} />)

    expect(screen.getByRole("status", { name: /Chat turn crashed .* not retryable .* 0 left/ })).toBeInTheDocument()
    expect(screen.getByText("Auto-retry exhausted")).toBeInTheDocument()
    expect(screen.getByText("attempt 3/3")).toBeInTheDocument()
    expect(screen.queryByText(/next/)).not.toBeInTheDocument()
  })
})
