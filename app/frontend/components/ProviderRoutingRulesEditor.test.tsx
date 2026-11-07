import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import type { FormEvent } from "react"
import { describe, expect, it, vi } from "vitest"
import { ProviderRoutingRulesEditor, RoutingRulesPanel } from "./ProviderRoutingRulesEditor"
import { conditionSummaries, DAYS, investigationMode, setInvestigationMode, setUsageComparison, usageHint } from "./providerRoutingConditions"
import type {
  ProviderRoutingExplainInput,
  ProviderRoutingExplanation,
  ProviderRoutingInheritedContext,
  ProviderRoutingOptions,
  ProviderRoutingRule,
  ProviderRoutingRuleInput
} from "../api/providerRoutingRules"

const options: ProviderRoutingOptions = {
  agent_providers: [
    { value: "codex", label: "Codex", configured: true, models: [{ id: "gpt-5", label: "GPT-5" }] },
    { value: "claude", label: "Claude", configured: true, models: [{ id: "sonnet", label: "Sonnet" }] }
  ],
  effort_levels: [
    { value: "low", label: "Low" },
    { value: "high", label: "High" }
  ],
  triggers: {
    step_kinds: [
      { value: "implement", label: "Implement" },
      { value: "rebase", label: "Rebase" },
      { value: "adversarial_review", label: "Adversarial review", panel_capable: true },
      { value: "security_review", label: "Security review", panel_capable: true }
    ],
    chat_roles: [{ value: "chat:supervisor", label: "Supervisor" }]
  },
  conditions: {
    workflow_trigger_kinds: [
      { value: "initial", label: "Initial" },
      { value: "ci_failure", label: "CI failure" }
    ],
    provider_usage: [{ provider: "codex", state: "available", remaining_percent: 20, observed_at: "2026-11-02T12:00:00Z" }],
    job_kinds: [
      { value: "issue", label: "Issue" },
      { value: "cron", label: "Cron" }
    ],
    repositories: [
      { id: 7, owner: "acme", name: "widgets", slug: "acme/widgets" },
      { id: 8, owner: "globex", name: "gadgets", slug: "globex/gadgets" }
    ],
    time_zone: "UTC"
  },
  action_strategies: [
    { value: "fallback_order", label: "Fallback order" },
    { value: "weighted", label: "Weighted" },
    { value: "panel", label: "Panel" }
  ],
  condition_keys: []
}

const rules: ProviderRoutingRule[] = [
  {
    id: 11,
    scope_type: "repository",
    scope_id: 7,
    position: 1,
    task_key: "implement",
    trigger: { type: "step", kind: "implement" },
    conditions: { workflow_trigger_kind: ["initial"] },
    action: { strategy: "fallback_order", name: "CI fast path", candidates: [{ provider: "codex", model: "gpt-5", effort_level: "high" }] },
    candidates: [{ provider: "codex", model: "gpt-5", effort_level: "high" }]
  },
  {
    id: 12,
    scope_type: "repository",
    scope_id: 7,
    position: 2,
    task_key: "default",
    trigger: { type: "default" },
    conditions: {},
    action: { strategy: "fallback_order", name: "General fallback", candidates: [{ provider: "claude", model: "sonnet" }] },
    candidates: [{ provider: "claude", model: "sonnet" }]
  }
]

const inheritedContext: ProviderRoutingInheritedContext[] = [
  {
    scope_type: "user",
    scope_id: 3,
    label: "User defaults",
    rules: [
      {
        id: 21,
        scope_type: "user",
        scope_id: 3,
        position: 1,
        task_key: "default",
        trigger: { type: "default" },
        conditions: {},
        action: { strategy: "fallback_order", name: "Inherited default", candidates: [{ provider: "claude" }] },
        candidates: [{ provider: "claude" }]
      }
    ]
  }
]

const legacyRules: ProviderRoutingRule[] = [
  {
    id: 31,
    scope_type: "user",
    scope_id: 3,
    position: 1,
    task_key: "ci_failure",
    trigger: { type: "legacy_task", task_key: "ci_failure" },
    conditions: {},
    action: { strategy: "fallback_order", name: "Legacy CI fallback", candidates: [{ provider: "codex" }] },
    candidates: [{ provider: "codex" }]
  }
]

const emptyWorkflowConditionRules: ProviderRoutingRule[] = [
  {
    id: 41,
    scope_type: "user",
    scope_id: 3,
    position: 1,
    task_key: "default",
    trigger: { type: "default" },
    conditions: { workflow_trigger_kind: [] },
    action: { strategy: "fallback_order", name: "Any workflow", candidates: [{ provider: "codex" }] },
    candidates: [{ provider: "codex" }]
  }
]

describe("ProviderRoutingRulesEditor", () => {
  it("renders ordered first-match rules with read-only inherited rows", () => {
    renderPanel({ inheritedContext, rules })

    expect(screen.getByText("Disabled rules are skipped; the first enabled matching rule wins.")).toBeInTheDocument()
    expect(screen.getByText("CI fast path")).toBeInTheDocument()
    expect(screen.getByText("Step: Implement")).toBeInTheDocument()
    expect(screen.getByText("Workflow: Initial")).toBeInTheDocument()
    expect(screen.getByText("Fallback: Codex")).toBeInTheDocument()
    expect(screen.getByText("User defaults")).toBeInTheDocument()
    expect(screen.getByText("Inherited default")).toBeInTheDocument()
    expect(screen.getByText("Read-only")).toBeInTheDocument()
    expect(screen.getAllByTestId("routing-rule-row")[0]).not.toHaveTextContent(/^1/)
  })

  it("summarizes fallback, load balancing, and hold actions without competing numbered lists", () => {
    const strategyRules: ProviderRoutingRule[] = [
      {
        ...rules[0],
        action: {
          strategy: "fallback_order",
          name: "Fallback lane",
          candidates: [{ provider: "codex" }, { provider: "claude" }]
        }
      },
      {
        ...rules[1],
        action: {
          strategy: "weighted",
          name: "Balanced lane",
          candidates: [
            { provider: "codex", weight: 60 },
            { provider: "claude", weight: 40 }
          ]
        }
      },
      {
        ...rules[1],
        id: 13,
        action: {
          strategy: "panel",
          name: "Review panel",
          candidates: [{ provider: "codex" }, { provider: "claude" }],
          consensus: "majority"
        }
      },
      {
        ...rules[1],
        id: 14,
        action: {
          type: "hold",
          name: "Maintenance window",
          reason: "Outside support hours",
          resumption: { mode: "manual" }
        }
      }
    ]

    renderPanel({ rules: strategyRules })

    expect(screen.getByText("Fallback: Codex → Claude")).toBeInTheDocument()
    expect(screen.getByText("Load balance: Codex (60) · Claude (40)")).toBeInTheDocument()
    expect(screen.getByText("Panel: Codex · Claude")).toBeInTheDocument()
    expect(screen.getByText("Hold: Outside support hours · Manual release")).toBeInTheDocument()
    expect(screen.queryByRole("list", { name: /Codex/ })).not.toBeInTheDocument()
  })

  it("renders bordered rows with icon actions and reorders from the drag handle", () => {
    const onReorderRules = vi.fn()
    renderPanel({ onReorderRules, rules })

    const rulesList = screen.getByRole("list", { name: "Provider routing rules" })
    expect(rulesList.parentElement).toHaveClass("border")

    const edit = screen.getByRole("button", { name: "Edit CI fast path" })
    const duplicate = screen.getByRole("button", { name: "Duplicate CI fast path" })
    const remove = screen.getByRole("button", { name: "Delete CI fast path" })
    expect(edit).toHaveTextContent("")
    expect(duplicate).toHaveTextContent("")
    expect(remove).toHaveTextContent("")
    expect(edit.parentElement).toHaveAttribute("role", "group")

    const handle = screen.getByRole("button", { name: "Reorder CI fast path" })
    const target = screen.getAllByTestId("routing-rule-row")[1]
    const dataTransfer = { dropEffect: "none", effectAllowed: "none", setData: vi.fn() }
    fireEvent.dragStart(handle, { dataTransfer })
    fireEvent.dragOver(target, { dataTransfer })
    fireEvent.drop(target, { dataTransfer })

    expect(dataTransfer.setData).toHaveBeenCalledWith("text/plain", "11")
    expect(onReorderRules).toHaveBeenCalledWith([12, 11])
  })

  it("opens and closes the modal and displays validation errors", () => {
    renderPanel({ rules: [] })

    expect(screen.getByText("No routing rules yet.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    expect(screen.getByRole("dialog", { name: "New routing rule" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Create rule" }))
    expect(screen.getByText("Enter a rule name.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "New routing rule" })).not.toBeInTheDocument()
  })

  it("creates a rule on Enter in a text field without submitting a parent form", async () => {
    const onCreateRule = vi.fn()
    const onParentSubmit = vi.fn((event: FormEvent<HTMLFormElement>) => event.preventDefault())
    render(
      <form onSubmit={onParentSubmit}>
        <RoutingRulesPanel
          description="Choose providers."
          onCreateRule={onCreateRule}
          onDeleteRule={vi.fn()}
          onReorderRules={vi.fn()}
          onUpdateRule={vi.fn()}
          options={options}
          rules={[]}
          title="Provider routing rules"
        />
      </form>
    )

    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.change(within(dialog).getByLabelText(/Rule name/), { target: { value: "Default lane" } })
    fireEvent.keyDown(within(dialog).getByLabelText(/Rule name/), { key: "Enter" })

    await waitFor(() =>
      expect(onCreateRule).toHaveBeenCalledWith(
        expect.objectContaining({
          action: expect.objectContaining({ name: "Default lane" }),
          task_key: "default",
          trigger: { type: "default" }
        })
      )
    )
    expect(onParentSubmit).not.toHaveBeenCalled()
    expect(screen.queryByRole("dialog", { name: "New routing rule" })).not.toBeInTheDocument()
  })

  it("creates a review panel with consensus and unavailable-member policy", async () => {
    const onUpdateRule = vi.fn()
    const panelRule: ProviderRoutingRule = {
      id: 51,
      scope_type: "repository",
      scope_id: 7,
      task_key: "security_review",
      trigger: { type: "step", kind: "security_review" },
      conditions: {},
      action: {
        strategy: "panel",
        name: "Security panel",
        candidates: [{ provider: "codex" }, { provider: "claude" }],
        consensus: { at_least: 2 },
        on_unavailable: "hold",
        min_members: 2
      },
      candidates: [{ provider: "codex" }, { provider: "claude" }]
    }
    renderPanel({ onUpdateRule, rules: [panelRule] })

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        panelRule,
        expect.objectContaining({
          trigger: { type: "step", kind: "security_review" },
          action: expect.objectContaining({
            strategy: "panel",
            consensus: { at_least: 2 },
            on_unavailable: "hold",
            min_members: 2,
            candidates: [{ provider: "codex" }, { provider: "claude" }]
          })
        })
      )
    )
  })

  it("displays mutation error states", () => {
    renderPanel({ rules, saveError: new Error("Provider is unavailable") })

    expect(screen.getByText("Unable to save routing rule.")).toBeInTheDocument()
  })

  it("does not render a blank workflow condition pill for empty workflow conditions", () => {
    renderPanel({ rules: emptyWorkflowConditionRules })

    expect(screen.getByText("Any workflow")).toBeInTheDocument()
    expect(screen.getByText("Any agent invocation")).toBeInTheDocument()
    expect(screen.queryByText(/^Workflow:/)).not.toBeInTheDocument()
  })

  it("preserves usage, budget, and unknown conditions when saving through the form", async () => {
    const onUpdateRule = vi.fn()
    const rich: ProviderRoutingRule = {
      ...rules[0],
      conditions: { workflow_trigger_kind: ["initial"], usage: { provider: "codex", remaining_percent: { lt: 25 } }, budget: { max: 5 }, mystery: true }
    }
    renderPanel({ onUpdateRule, rules: [rich] })

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.click(within(dialog).getByLabelText("CI failure"))
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        rich,
        expect.objectContaining({
          conditions: {
            workflow_trigger_kind: ["initial", "ci_failure"],
            usage: { provider: "codex", remaining_percent: { lt: 25 } },
            budget: { max: 5 },
            mystery: true
          }
        })
      )
    )
  })

  it("adds and removes the workflow trigger condition and searches kinds", async () => {
    const onCreateRule = vi.fn()
    renderPanel({ onCreateRule, rules: [] })

    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    expect(within(dialog).getByText("Always applies.")).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Add condition" }))
    expect(within(dialog).queryByText(/budget/i)).not.toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Workflow trigger" }))
    expect(within(dialog).queryByRole("button", { name: "Workflow trigger" })).not.toBeInTheDocument()

    fireEvent.change(within(dialog).getByLabelText("Search triggers"), { target: { value: "ci" } })
    expect(within(dialog).queryByLabelText("Initial")).not.toBeInTheDocument()
    fireEvent.keyDown(within(dialog).getByLabelText("Search triggers"), { key: "Enter" })
    expect(onCreateRule).not.toHaveBeenCalled()
    fireEvent.click(within(dialog).getByLabelText("CI failure"))

    fireEvent.change(within(dialog).getByLabelText(/Rule name/), { target: { value: "R" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create rule" }))
    await waitFor(() => expect(onCreateRule).toHaveBeenCalledWith(expect.objectContaining({ conditions: { workflow_trigger_kind: ["ci_failure"] } })))

    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const again = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.click(within(again).getByRole("button", { name: "Add condition" }))
    fireEvent.click(within(again).getByRole("button", { name: "Workflow trigger" }))
    fireEvent.click(within(again).getByRole("button", { name: "Remove condition: Workflow trigger" }))
    expect(within(again).getByText("Always applies.")).toBeInTheDocument()
  })

  it.each([
    ["remaining_percent_less_than", "less than"],
    ["remaining_percent_less_than_or_equal_to", "at most"],
    ["remaining_percent_greater_than", "more than"],
    ["remaining_percent_greater_than_or_equal_to", "at least"]
  ])("round-trips the usage card through stored JSON for %s", async (key, label) => {
    const onCreateRule = vi.fn()
    renderPanel({ onCreateRule, rules: [] })

    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Add condition" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Provider usage" }))
    fireEvent.change(within(dialog).getByLabelText("Usage provider"), { target: { value: "codex" } })
    fireEvent.change(within(dialog).getByLabelText("Comparator"), { target: { value: key } })
    expect(within(dialog).getByRole("option", { name: label })).toBeInTheDocument()
    fireEvent.change(within(dialog).getByLabelText("Percent left"), { target: { value: "40" } })
    fireEvent.change(within(dialog).getByLabelText(/Rule name/), { target: { value: "R" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create rule" }))

    await waitFor(() => expect(onCreateRule).toHaveBeenCalledWith(expect.objectContaining({ conditions: { usage: { provider: "codex", [key]: 40 } } })))
  })

  it("stores provider states from the More disclosure and keeps them on save", async () => {
    const onUpdateRule = vi.fn()
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { usage: { provider: "codex", remaining_percent_less_than: 25 } } }
    renderPanel({ onUpdateRule, rules: [rule] })

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "More" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Rate limited" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        rule,
        expect.objectContaining({ conditions: { usage: { provider: "codex", states: ["rate_limited"], remaining_percent_less_than: 25 } } })
      )
    )
  })

  it("keeps the chosen usage comparator when the percent is cleared and retyped", async () => {
    const onUpdateRule = vi.fn()
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { usage: { provider: "codex", remaining_percent_less_than: 25 } } }
    renderPanel({ onUpdateRule, rules: [rule] })

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.change(within(dialog).getByLabelText("Comparator"), { target: { value: "remaining_percent_greater_than_or_equal_to" } })
    fireEvent.change(within(dialog).getByLabelText("Percent left"), { target: { value: "" } })
    expect(within(dialog).getByLabelText("Comparator")).toHaveValue("remaining_percent_greater_than_or_equal_to")
    fireEvent.change(within(dialog).getByLabelText("Percent left"), { target: { value: "60" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        rule,
        expect.objectContaining({ conditions: { usage: { provider: "codex", remaining_percent_greater_than_or_equal_to: 60 } } })
      )
    )
  })

  it("rejects usage percents outside 0-100 and blocks saving", () => {
    const onUpdateRule = vi.fn()
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { usage: { provider: "codex", remaining_percent_less_than: 25 } } }
    renderPanel({ onUpdateRule, rules: [rule] })

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.change(within(dialog).getByLabelText("Percent left"), { target: { value: "150" } })
    expect(within(dialog).getByText("Enter a percent from 0 to 100.")).toBeInTheDocument()
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))
    expect(onUpdateRule).not.toHaveBeenCalled()
  })

  it("summarizes the usage condition in the rule list and shows the live hint in the card", () => {
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { usage: { provider: "codex", remaining_percent_less_than: 25 } } }
    renderPanel({ rules: [rule] })

    expect(screen.getByText("Codex < 25% left")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    expect(within(screen.getByRole("dialog", { name: "Edit routing rule" })).getByText("Codex: 20% left now - matches")).toBeInTheDocument()
  })

  async function createWithCondition(label: string, interact: (dialog: HTMLElement) => void) {
    const onCreateRule = vi.fn()
    renderPanel({ onCreateRule, rules: [] })
    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Add condition" }))
    fireEvent.click(within(dialog).getByRole("button", { name: label }))
    interact(dialog)
    fireEvent.change(within(dialog).getByLabelText(/Rule name/), { target: { value: "R" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create rule" }))
    return onCreateRule
  }

  it("round-trips the day and time card through stored JSON", async () => {
    const onCreateRule = await createWithCondition("Day and time", (dialog) => {
      // Defaults to Mon-Fri 09:00-18:00; drop Friday, add Sunday, and move the start.
      fireEvent.click(within(dialog).getByRole("button", { name: "Fri" }))
      fireEvent.click(within(dialog).getByRole("button", { name: "Sun" }))
      fireEvent.change(within(dialog).getByLabelText("Start time"), { target: { value: "08:30" } })
      expect(within(dialog).getByText("Server time zone: UTC")).toBeInTheDocument()
    })

    await waitFor(() =>
      expect(onCreateRule).toHaveBeenCalledWith(
        expect.objectContaining({ conditions: { day_time: { days: ["monday", "tuesday", "wednesday", "thursday", "sunday"], start: "08:30", end: "18:00" } } })
      )
    )
  })

  it("blocks saving an overnight day and time window", () => {
    const onCreateRule = vi.fn()
    renderPanel({ onCreateRule, rules: [] })
    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Add condition" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Day and time" }))
    fireEvent.change(within(dialog).getByLabelText("Start time"), { target: { value: "22:00" } })
    fireEvent.change(within(dialog).getByLabelText("End time"), { target: { value: "06:00" } })
    expect(within(dialog).getAllByText("Start must be before end. For overnight windows, use two rules.").length).toBeGreaterThan(0)
    fireEvent.change(within(dialog).getByLabelText(/Rule name/), { target: { value: "R" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Create rule" }))
    expect(onCreateRule).not.toHaveBeenCalled()
  })

  it("summarizes day and time conditions tersely", () => {
    const t = (key: string) => key.split("short_")[1] ?? key
    const summary = (value: unknown) => conditionSummaries({ day_time: value as Record<string, unknown> }, options, t as never)[0]
    expect(summary({ days: DAYS.slice(0, 5), start: "09:00", end: "18:00" })).toBe("monday-friday 09:00-18:00")
    expect(summary({ days: ["monday", "wednesday"], end: "12:00" })).toContain("monday, wednesday")
    expect(summary({ days: [...DAYS], start: "09:00", end: "10:00" })).toBe("09:00-10:00")
  })

  it("shows day and time as Mon-Fri 09:00-18:00 in the rule list", () => {
    const rule: ProviderRoutingRule = {
      ...rules[0],
      conditions: { day_time: { days: ["monday", "tuesday", "wednesday", "thursday", "friday"], start: "09:00", end: "18:00" } }
    }
    renderPanel({ rules: [rule] })
    expect(screen.getByText("Mon-Fri 09:00-18:00")).toBeInTheDocument()
  })

  it("round-trips the job type card through stored JSON", async () => {
    const onCreateRule = await createWithCondition("Job type", (dialog) => {
      fireEvent.click(within(dialog).getByRole("button", { name: "Issue" }))
      fireEvent.click(within(dialog).getByRole("button", { name: "High" }))
      fireEvent.click(within(dialog).getByRole("button", { name: "Urgent" }))
      fireEvent.click(within(dialog).getByRole("radio", { name: "Only investigations" }))
    })

    await waitFor(() =>
      expect(onCreateRule).toHaveBeenCalledWith(
        expect.objectContaining({ conditions: { job_metadata: { kinds: ["issue"], priorities: ["high", "urgent"], investigation: true } } })
      )
    )
  })

  it("stores never-investigations as false and drops the key for any", () => {
    expect(setInvestigationMode({ kinds: ["issue"] }, "never")).toEqual({ kinds: ["issue"], investigation: false })
    expect(investigationMode({ investigation: false })).toBe("never")
    expect(setInvestigationMode({ investigation: false }, "any")).toEqual({})
  })

  it("summarizes job type as High/Urgent and drops an emptied job type on save", async () => {
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { job_metadata: { priorities: ["high", "urgent"] } } }
    const onUpdateRule = vi.fn()
    renderPanel({ onUpdateRule, rules: [rule] })
    expect(screen.getByText("High/Urgent")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "High" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Urgent" }))
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))
    await waitFor(() => expect(onUpdateRule).toHaveBeenCalledWith(rule, expect.objectContaining({ conditions: {} })))
  })

  it("round-trips the repository card through stored JSON", async () => {
    const onCreateRule = await createWithCondition("Repository", (dialog) => {
      fireEvent.click(within(dialog).getByLabelText("acme/widgets"))
      fireEvent.click(within(dialog).getByRole("button", { name: "globex" }))
    })

    await waitFor(() => expect(onCreateRule).toHaveBeenCalledWith(expect.objectContaining({ conditions: { repository: { ids: [7], owners: ["globex"] } } })))
  })

  it("summarizes the repository condition with truncation", () => {
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { repository: { ids: [7], owners: ["a-very-long-owner-name-indeed"] } } }
    renderPanel({ rules: [rule] })
    expect(screen.getByText("Repo: acme/widgets, a-very-long-owner-name-…")).toBeInTheDocument()
  })

  it.each([
    ["repository", false],
    ["job", false],
    ["user", true]
  ] as const)("offers the repository condition at %s scope: %s", (scope, offered) => {
    renderPanel({ rules: [], scope })
    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    const dialog = screen.getByRole("dialog", { name: "New routing rule" })
    fireEvent.click(within(dialog).getByRole("button", { name: "Add condition" }))
    expect(within(dialog).queryByRole("button", { name: "Repository" }) !== null).toBe(offered)
  })

  it("hides but preserves an existing repository condition at repository scope", async () => {
    const rule: ProviderRoutingRule = { ...rules[0], conditions: { repository: { owners: ["acme"] } } }
    const onUpdateRule = vi.fn()
    renderPanel({ onUpdateRule, rules: [rule], scope: "repository" })
    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    expect(within(dialog).queryByRole("button", { name: "Remove condition: Repository" })).toBeNull()
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))
    await waitFor(() => expect(onUpdateRule).toHaveBeenCalledWith(rule, expect.objectContaining({ conditions: { repository: { owners: ["acme"] } } })))
  })

  it("builds usage hints for matching, non-matching, and unread providers", () => {
    const t = (key: string, vars?: Record<string, unknown>) => `${key}:${JSON.stringify(vars)}`
    expect(usageHint({ provider: "codex", remaining_percent_greater_than: 50 }, options, t)).toContain("hint_no_match")
    expect(usageHint({ provider: "codex", remaining_percent_less_than: 25, states: ["exhausted"] }, options, t)).toContain("hint_no_match")
    expect(usageHint({ provider: "claude", remaining_percent_less_than: 25 }, options, t)).toContain("hint_unknown")
    expect(usageHint({ remaining_percent_less_than: 25 }, options, t)).toBeNull()
    expect(setUsageComparison({ provider: "codex", remaining_percent_less_than: 1 }, "remaining_percent_greater_than", "")).toEqual({ provider: "codex" })
  })

  it("summarizes conditions tersely and collapses unknown ones", () => {
    const withUnknown: ProviderRoutingRule = {
      ...rules[0],
      conditions: { workflow_trigger_kind: ["initial", "ci_failure"], usage: { x: 1 }, mystery: 1, budget: { max: 1 } }
    }
    renderPanel({ rules: [withUnknown] })

    expect(screen.getByText("Workflow: Initial, CI failure")).toBeInTheDocument()
    expect(screen.getByText("+1 other")).toBeInTheDocument()
    expect(screen.queryByText("usage")).not.toBeInTheDocument()
    expect(screen.queryByText("budget")).not.toBeInTheDocument()
  })

  it("edits, duplicates, deletes, and reorders rules through panel callbacks", async () => {
    const onCreateRule = vi.fn()
    const onUpdateRule = vi.fn()
    const onDeleteRule = vi.fn()
    const onReorderRules = vi.fn()
    renderPanel({ onCreateRule, onDeleteRule, onReorderRules, onUpdateRule, rules })

    fireEvent.click(screen.getByRole("button", { name: "Edit CI fast path" }))
    const editDialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.change(within(editDialog).getByLabelText(/Rule name/), { target: { value: "Rebase lane" } })
    fireEvent.change(within(editDialog).getByLabelText(/Trigger/), { target: { value: "step:rebase" } })
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        rules[0],
        expect.objectContaining({
          action: expect.objectContaining({ name: "Rebase lane", strategy: "fallback_order" }),
          task_key: "rebase",
          trigger: { type: "step", kind: "rebase" }
        })
      )
    )

    fireEvent.click(screen.getByRole("button", { name: "Duplicate CI fast path" }))
    const duplicateDialog = screen.getByRole("dialog", { name: "New routing rule" })
    expect(within(duplicateDialog).getByLabelText(/Rule name/)).toHaveValue("CI fast path copy")
    fireEvent.click(within(duplicateDialog).getByRole("button", { name: "Create rule" }))
    await waitFor(() =>
      expect(onCreateRule).toHaveBeenCalledWith(
        expect.objectContaining({
          action: expect.objectContaining({ name: "CI fast path copy" })
        })
      )
    )

    fireEvent.click(screen.getByRole("button", { name: "Delete CI fast path" }))
    expect(onDeleteRule).toHaveBeenCalledWith(rules[0])

    fireEvent.keyDown(screen.getByRole("button", { name: "Reorder CI fast path" }), { key: "ArrowDown" })
    expect(onReorderRules).toHaveBeenCalledWith([12, 11])
  })

  it("toggles disabled rules in place and edits hold actions without provider candidates", async () => {
    const onToggleRule = vi.fn()
    const onUpdateRule = vi.fn()
    const holdRule: ProviderRoutingRule = {
      ...rules[0],
      enabled: false,
      action: { type: "hold", name: "Maintenance window", reason: "Deploy freeze", resumption: { mode: "manual" } },
      candidates: []
    }
    renderPanel({ onToggleRule, onUpdateRule, rules: [holdRule, rules[1]] })

    expect(screen.getByText("Disabled")).toBeInTheDocument()
    expect(screen.getByText("Hold: Deploy freeze · Manual release")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("checkbox", { name: "Enable Maintenance window" }))
    expect(onToggleRule).toHaveBeenCalledWith(holdRule, true)

    fireEvent.click(screen.getByRole("button", { name: "Edit Maintenance window" }))
    const dialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    expect(within(dialog).getByLabelText("Action type")).toHaveValue("hold")
    expect(within(dialog).queryByText("Provider candidates")).not.toBeInTheDocument()
    fireEvent.change(within(dialog).getByLabelText(/Hold reason/), { target: { value: "Await approval" } })
    fireEvent.change(within(dialog).getByLabelText("Resumption policy"), { target: { value: "when_conditions_clear" } })
    fireEvent.click(within(dialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        holdRule,
        expect.objectContaining({
          action: expect.objectContaining({ type: "hold", reason: "Await approval", resumption: { mode: "when_conditions_clear" } }),
          candidates: []
        })
      )
    )
  })

  it("closes the edit draft after deleting the edited rule", async () => {
    const onDeleteRule = vi.fn()
    renderPanel({ onDeleteRule, rules })

    fireEvent.click(screen.getByRole("button", { name: "Edit CI fast path" }))
    expect(screen.getByRole("dialog", { name: "Edit routing rule" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Delete CI fast path" }))

    await waitFor(() => expect(onDeleteRule).toHaveBeenCalledWith(rules[0]))
    expect(screen.queryByRole("dialog", { name: "Edit routing rule" })).not.toBeInTheDocument()
  })

  it("wires edits, creates, deletes, and reorders through the API adapter", async () => {
    const fetchMock = vi.fn(async (path: RequestInfo | URL, init?: RequestInit) => {
      return new Response(JSON.stringify({ provider_routing_rules: rules, provider_routing_options: options }), {
        status: String(init?.method) === "POST" ? 201 : 200,
        headers: { "Content-Type": "application/json" }
      })
    })
    vi.stubGlobal("fetch", fetchMock)
    renderEditor({ rules })

    fireEvent.click(screen.getByRole("button", { name: "Edit CI fast path" }))
    const editDialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    fireEvent.change(within(editDialog).getByLabelText(/Rule name/), { target: { value: "Rebase lane" } })
    fireEvent.change(within(editDialog).getByLabelText(/Trigger/), { target: { value: "step:rebase" } })
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/11", expect.objectContaining({ method: "PATCH" })))
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body)).provider_routing_rule).toMatchObject({
      task_key: "rebase",
      trigger: { type: "step", kind: "rebase" },
      action: { name: "Rebase lane", strategy: "fallback_order" }
    })

    fireEvent.click(screen.getByRole("button", { name: "Duplicate CI fast path" }))
    const duplicateDialog = screen.getByRole("dialog", { name: "New routing rule" })
    expect(within(duplicateDialog).getByLabelText(/Rule name/)).toHaveValue("CI fast path copy")
    fireEvent.click(within(duplicateDialog).getByRole("button", { name: "Create rule" }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules", expect.objectContaining({ method: "POST" })))

    fireEvent.click(screen.getByRole("button", { name: "Delete CI fast path" }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/11", expect.objectContaining({ method: "DELETE" })))

    fireEvent.keyDown(screen.getByRole("button", { name: "Reorder CI fast path" }), { key: "ArrowDown" })
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/reorder", expect.objectContaining({ method: "PATCH" })))
    const reorderBody = JSON.parse(String(fetchMock.mock.calls.at(-1)?.[1]?.body))
    expect(reorderBody.provider_routing_rule_ids).toEqual([12, 11])
  })

  it("rolls an optimistic reorder back when persistence fails", async () => {
    let rejectReorder: ((reason?: unknown) => void) | undefined
    vi.stubGlobal(
      "fetch",
      vi.fn((path: RequestInfo | URL) => {
        if (String(path).endsWith("/reorder")) {
          return new Promise<Response>((_resolve, reject) => {
            rejectReorder = reject
          })
        }
        return Promise.resolve(new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } }))
      })
    )
    renderEditor({ rules })

    fireEvent.keyDown(screen.getByRole("button", { name: "Reorder CI fast path" }), { key: "ArrowDown" })
    expect(ruleRowNames()).toEqual(["General fallback", "CI fast path"])

    await waitFor(() => expect(rejectReorder).toBeTypeOf("function"))
    rejectReorder!(new Error("network unavailable"))
    await waitFor(() => {
      expect(ruleRowNames()).toEqual(["CI fast path", "General fallback"])
    })
  })

  it("preserves legacy task-key triggers when editing existing rules", async () => {
    const onUpdateRule = vi.fn()
    renderPanel({ onUpdateRule, rules: legacyRules })

    expect(screen.getByText("Legacy task: ci_failure")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /^Edit / }))
    const editDialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    expect(within(editDialog).getByLabelText(/Trigger/)).toHaveValue("legacy_task:ci_failure")

    fireEvent.change(within(editDialog).getByLabelText(/Rule name/), { target: { value: "Still CI failure" } })
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() =>
      expect(onUpdateRule).toHaveBeenCalledWith(
        legacyRules[0],
        expect.objectContaining({
          action: expect.objectContaining({ name: "Still CI failure" }),
          task_key: "ci_failure",
          trigger: { type: "legacy_task", task_key: "ci_failure" }
        })
      )
    )
  })
})

function renderEditor({ inheritedContext, rules }: { inheritedContext?: ProviderRoutingInheritedContext[]; rules: ProviderRoutingRule[] }) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <ProviderRoutingRulesEditor
        basePath="/api/test/provider_routing_rules"
        description="Choose providers."
        inheritedContext={inheritedContext}
        options={options}
        queryKey={["provider-routing-rules-test"]}
        rules={rules}
        title="Provider routing rules"
      />
    </QueryClientProvider>
  )
}

function ruleRowNames() {
  return screen.getAllByTestId("routing-rule-row").map((row) => (row.textContent?.includes("CI fast path") ? "CI fast path" : "General fallback"))
}

function renderPanel({
  inheritedContext,
  onCreateRule = vi.fn(),
  onDeleteRule = vi.fn(),
  onReorderRules = vi.fn(),
  onToggleRule = vi.fn(),
  onUpdateRule = vi.fn(),
  saveError,
  scope,
  rules
}: {
  inheritedContext?: ProviderRoutingInheritedContext[]
  onCreateRule?: (input: ProviderRoutingRuleInput) => unknown
  onDeleteRule?: (rule: ProviderRoutingRule) => unknown
  onReorderRules?: (ids: number[]) => unknown
  onToggleRule?: (rule: ProviderRoutingRule, enabled: boolean) => unknown
  onUpdateRule?: (rule: ProviderRoutingRule, input: ProviderRoutingRuleInput) => unknown
  saveError?: unknown
  scope?: "user" | "repository" | "job"
  rules: ProviderRoutingRule[]
}) {
  return render(
    <RoutingRulesPanel
      description="Choose providers."
      inheritedContext={inheritedContext}
      onCreateRule={onCreateRule}
      onDeleteRule={onDeleteRule}
      onReorderRules={onReorderRules}
      onToggleRule={onToggleRule}
      onUpdateRule={onUpdateRule}
      options={options}
      rules={rules}
      saveError={saveError}
      scope={scope}
      title="Provider routing rules"
    />
  )
}

describe("RoutingTestPanel", () => {
  const explanation = (overrides: Record<string, unknown> = {}) => ({
    job_id: 5,
    scope_precedence: [
      {
        scope_type: "user",
        scope_id: 1,
        rules: [
          {
            id: 1,
            position: 1,
            enabled: true,
            outcome: "match_failed",
            winning: false,
            evidence: [
              {
                matched: false,
                trigger: { matched: true },
                conditions: {
                  usage: {
                    configured: true,
                    matched: false,
                    expected: { provider: "codex", remaining_percent_less_than: 25 },
                    actual: { provider: "codex", remaining_percent: 31 }
                  }
                }
              }
            ]
          },
          {
            id: 2,
            position: 2,
            enabled: true,
            outcome: "matched_winner",
            winning: true,
            evidence: [{ matched: true, trigger: { matched: true }, conditions: {} }]
          },
          { id: 3, position: 3, enabled: true, outcome: "not_evaluated_after_winner", winning: false, evidence: [] }
        ]
      }
    ],
    winning_decision: {
      decision: { status: "routed" },
      matched_rule: { id: 2 },
      final_action: { candidates: [{ provider: "claude" }, { provider: "codex" }] }
    },
    ...overrides
  })

  function renderPanel(onExplain: (input: ProviderRoutingExplainInput) => Promise<ProviderRoutingExplanation>) {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            JSON.stringify({ count: 1, jobs: [{ id: 5, title: "Fix it", issue_title: "Fix it", state: "open", repository_slug: "a/b", pr_url: null }] }),
            {
              status: 200,
              headers: { "Content-Type": "application/json" }
            }
          )
      )
    )
    render(
      <QueryClientProvider client={client}>
        <RoutingRulesPanel
          description="d"
          onCreateRule={vi.fn()}
          onDeleteRule={vi.fn()}
          onExplain={onExplain}
          onReorderRules={vi.fn()}
          onUpdateRule={vi.fn()}
          options={options}
          rules={[]}
          title="t"
        />
      </QueryClientProvider>
    )
    fireEvent.click(screen.getByRole("button", { name: "Test" }))
  }

  async function runTest() {
    await screen.findByRole("option", { name: "JOB-5 Fix it" })
    fireEvent.change(screen.getAllByRole("combobox")[0], { target: { value: "5" } })
    fireEvent.click(screen.getByRole("button", { name: "Run test" }))
  }

  it("shows the winner line and per-rule reasons", async () => {
    const onExplain = vi.fn().mockResolvedValue(explanation() as unknown as ProviderRoutingExplanation)
    renderPanel(onExplain)
    await runTest()

    expect(await screen.findByText("Rule 2 wins: Claude, then Codex")).toBeInTheDocument()
    expect(onExplain).toHaveBeenCalledWith({ target_job_id: 5, task_key: "implement" })
    expect(screen.getByText(": skipped: Codex 31% not < 25%")).toBeInTheDocument()
    expect(screen.getByText(": matched")).toBeInTheDocument()
    expect(screen.getByText(": not evaluated")).toBeInTheDocument()
  })

  it("reports no winner and holds", async () => {
    const onExplain = vi.fn().mockResolvedValue(explanation({ scope_precedence: [], winning_decision: {} }) as unknown as ProviderRoutingExplanation)
    renderPanel(onExplain)
    await runTest()
    expect(await screen.findByText("No rule matches; default routing applies.")).toBeInTheDocument()
  })

  it("reports a held decision", async () => {
    const held = explanation({ winning_decision: { decision: { status: "held", reason: "Quota low" }, matched_rule: { id: 2 } } })
    renderPanel(vi.fn().mockResolvedValue(held))
    await runTest()
    expect(await screen.findByText("Rule 2 holds work: Quota low")).toBeInTheDocument()
  })

  it("shows an error when the test fails", async () => {
    renderPanel(vi.fn().mockRejectedValue(new Error("boom")))
    await runTest()
    expect(await screen.findByText("Unable to test routing rules.")).toBeInTheDocument()
  })
})
