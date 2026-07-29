import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { NeutralStatePill, WorkflowTriggerPill } from "./components"
import { CommitsBehindBadge } from "./JobsTable"
import i18n from "../../i18n"

describe("NeutralStatePill", () => {
  it("renders a known state using its translation", () => {
    render(<NeutralStatePill state="running" />)
    expect(screen.getByText("running")).toBeInTheDocument()
  })

  it("translates state labels into the active locale", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<NeutralStatePill state="running" />)
      expect(screen.getByText("läuft")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("humanizes unknown states as a fallback", () => {
    render(<NeutralStatePill state="custom_state" />)
    expect(screen.getByText("custom state")).toBeInTheDocument()
  })

  it("translates landing state into German", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<NeutralStatePill state="landing" />)
      expect(screen.getByText("wird gelandet")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })
})

describe("CommitsBehindBadge", () => {
  it("renders nothing when count is null", () => {
    const { container } = render(<CommitsBehindBadge count={null} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("renders nothing when count is zero", () => {
    const { container } = render(<CommitsBehindBadge count={0} />)
    expect(container).toBeEmptyDOMElement()
  })

  it("renders a gray badge for a small count (1-9)", () => {
    render(<CommitsBehindBadge count={5} />)
    const badge = screen.getByText("5 behind")
    expect(badge).toBeInTheDocument()
    expect(badge.closest("[data-status-pill]")).toHaveClass("bg-gray-100")
  })

  it("renders an amber badge for a mid-range count (10-19)", () => {
    render(<CommitsBehindBadge count={15} />)
    const badge = screen.getByText("15 behind")
    expect(badge).toBeInTheDocument()
    expect(badge.closest("[data-status-pill]")).toHaveClass("bg-amber-50")
  })

  it("renders a red badge for a high count (20+)", () => {
    render(<CommitsBehindBadge count={25} />)
    const badge = screen.getByText("25 behind")
    expect(badge).toBeInTheDocument()
    expect(badge.closest("[data-status-pill]")).toHaveClass("bg-red-50")
  })

  it("includes an aria-label describing the count", () => {
    render(<CommitsBehindBadge count={30} />)
    expect(screen.getByRole("generic", { name: "30 commits behind base" })).toBeInTheDocument()
  })
})

describe("WorkflowTriggerPill", () => {
  it("renders a known trigger kind using its translation", () => {
    render(<WorkflowTriggerPill ariaPrefix="Trigger" triggerKind="initial" />)
    expect(screen.getByText("initial")).toBeInTheDocument()
  })

  it("translates trigger kinds into the active locale", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<WorkflowTriggerPill ariaPrefix="Auslöser" triggerKind="pr_comment" />)
      expect(screen.getByText("PR-Kommentar")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("humanizes unknown trigger kinds as a fallback", () => {
    render(<WorkflowTriggerPill ariaPrefix="Trigger" triggerKind="unknown_kind" />)
    expect(screen.getByText("unknown kind")).toBeInTheDocument()
  })

  it("includes the translated label in the aria-label", () => {
    render(<WorkflowTriggerPill ariaPrefix="Trigger" triggerKind="auto_merge" />)
    expect(screen.getByRole("generic", { name: "Trigger: auto merge" })).toBeInTheDocument()
  })

  it("translates auto_merge into German", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<WorkflowTriggerPill ariaPrefix="Auslöser" triggerKind="auto_merge" />)
      expect(screen.getByText("Auto Merge")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })
})
