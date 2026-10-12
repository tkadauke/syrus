import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { ProviderRoutingRulesEditor } from "./ProviderRoutingRulesEditor"
import type { ProviderRoutingInheritedContext, ProviderRoutingOptions, ProviderRoutingRule } from "../api/providerRoutingRules"

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
      { value: "rebase", label: "Rebase" }
    ],
    chat_roles: [
      { value: "chat:supervisor", label: "Supervisor" }
    ]
  },
  conditions: {
    workflow_trigger_kinds: [
      { value: "initial", label: "Initial" },
      { value: "ci_failure", label: "CI failure" }
    ]
  },
  action_strategies: [
    { value: "fallback_order", label: "Fallback order" },
    { value: "weighted", label: "Weighted" }
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
    renderEditor({ inheritedContext, rules })

    expect(screen.getByText("Rules are evaluated from top to bottom; the first matching rule wins.")).toBeInTheDocument()
    expect(screen.getByText("CI fast path")).toBeInTheDocument()
    expect(screen.getByText("Step: Implement")).toBeInTheDocument()
    expect(screen.getByText("Workflow: Initial")).toBeInTheDocument()
    expect(screen.getByText("Codex / GPT-5 / High effort")).toBeInTheDocument()
    expect(screen.getByText("User defaults")).toBeInTheDocument()
    expect(screen.getByText("Inherited default")).toBeInTheDocument()
    expect(screen.getByText("Read-only")).toBeInTheDocument()
  })

  it("opens and closes the modal and displays validation errors", () => {
    renderEditor({ rules: [] })

    expect(screen.getByText("No routing rules yet.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "New rule" }))
    expect(screen.getByRole("dialog", { name: "New routing rule" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Create rule" }))
    expect(screen.getByText("Enter a rule name.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Cancel" }))
    expect(screen.queryByRole("dialog", { name: "New routing rule" })).not.toBeInTheDocument()
  })

  it("does not render a blank workflow condition pill for empty workflow conditions", () => {
    renderEditor({ rules: emptyWorkflowConditionRules })

    expect(screen.getByText("Any workflow")).toBeInTheDocument()
    expect(screen.getByText("Any agent invocation")).toBeInTheDocument()
    expect(screen.queryByText(/^Workflow:/)).not.toBeInTheDocument()
  })

  it("edits, duplicates, deletes, and reorders rules through the API", async () => {
    const fetchMock = vi.fn(async (path: RequestInfo | URL, init?: RequestInit) => {
      return new Response(JSON.stringify({ provider_routing_rules: rules, provider_routing_options: options }), {
        status: String(init?.method) === "POST" ? 201 : 200,
        headers: { "Content-Type": "application/json" }
      })
    })
    vi.stubGlobal("fetch", fetchMock)
    renderEditor({ rules })

    fireEvent.click(screen.getAllByRole("button", { name: "Edit" })[0])
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

    fireEvent.click(screen.getAllByRole("button", { name: "Duplicate" })[0])
    const duplicateDialog = screen.getByRole("dialog", { name: "New routing rule" })
    expect(within(duplicateDialog).getByLabelText(/Rule name/)).toHaveValue("CI fast path copy")
    fireEvent.click(within(duplicateDialog).getByRole("button", { name: "Create rule" }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules", expect.objectContaining({ method: "POST" })))

    fireEvent.click(screen.getAllByRole("button", { name: "Delete" })[0])
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/11", expect.objectContaining({ method: "DELETE" })))

    fireEvent.click(screen.getByRole("button", { name: "Move CI fast path down" }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/reorder", expect.objectContaining({ method: "PATCH" })))
    const reorderBody = JSON.parse(String(fetchMock.mock.calls.at(-1)?.[1]?.body))
    expect(reorderBody.provider_routing_rule_ids).toEqual([12, 11])
  })

  it("preserves legacy task-key triggers when editing existing rules", async () => {
    const fetchMock = vi.fn(async (_path: RequestInfo | URL, _init?: RequestInit) => {
      return new Response(JSON.stringify({ provider_routing_rules: legacyRules, provider_routing_options: options }), {
        status: 200,
        headers: { "Content-Type": "application/json" }
      })
    })
    vi.stubGlobal("fetch", fetchMock)
    renderEditor({ rules: legacyRules })

    expect(screen.getByText("Legacy task: ci_failure")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Edit" }))
    const editDialog = screen.getByRole("dialog", { name: "Edit routing rule" })
    expect(within(editDialog).getByLabelText(/Trigger/)).toHaveValue("legacy_task:ci_failure")

    fireEvent.change(within(editDialog).getByLabelText(/Rule name/), { target: { value: "Still CI failure" } })
    fireEvent.click(within(editDialog).getByRole("button", { name: "Save rule" }))

    await waitFor(() => expect(fetchMock).toHaveBeenCalledWith("/api/test/provider_routing_rules/31", expect.objectContaining({ method: "PATCH" })))
    expect(JSON.parse(String(fetchMock.mock.calls[0][1]?.body)).provider_routing_rule).toMatchObject({
      task_key: "ci_failure",
      trigger: { type: "legacy_task", task_key: "ci_failure" },
      action: { name: "Still CI failure" }
    })
  })
})

function renderEditor({
  inheritedContext,
  rules
}: {
  inheritedContext?: ProviderRoutingInheritedContext[]
  rules: ProviderRoutingRule[]
}) {
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
