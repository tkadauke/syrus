/-!
# Daemon tool wrappers must not depend on wrap order (F46, Lead L3)

The persistent MCP daemon serves chat and workflow routes in one process. A
tool available on both (the coworkers' `list_chats`, `search_chats`) has both
`ChatToolDispatch` and `WorkflowToolDispatch` prepended to its class, each
once, on first use, so the one wrapped *last* is outermost.

`WorkflowToolDispatch` passes a call through unless it came in on a workflow
route (`workflow_role` set). `ChatToolDispatch` passed through only when the
call carried no daemon identity; a workflow-route call does carry one. With the
chat wrapper outermost it tried to resolve a chat context from a run token and
refused the call ("invocation token surface :run is not chat"). Whether
coworker workflow calls worked therefore depended on which route wrapped the
tool first: process history.

After: the chat wrapper also passes through workflow-route calls. Each
wrapper then handles only its own route, and the result is the same in both
orders.
-/

namespace SyrusModel
namespace DispatchOrder

inductive Route where | chat | workflow deriving DecidableEq, Repr
inductive Outcome where | served | refused deriving DecidableEq, Repr

/-- A wrapper either serves the call, refuses it, or passes it inward. -/
inductive Step where | serve | refuse | pass deriving DecidableEq, Repr

def workflowWrapper : Route → Step
  | .workflow => .serve
  | .chat => .pass

/-- Before: any daemon call reaches chat resolution, which refuses a run token. -/
def chatWrapperBefore : Route → Step
  | .chat => .serve
  | .workflow => .refuse

def chatWrapperAfter : Route → Step
  | .chat => .serve
  | .workflow => .pass

/-- Run a call through wrappers listed outermost first. Served once a wrapper
    serves it (the inner ones then see a resolved, identity-free context). -/
def runWrappers : List (Route → Step) → Route → Outcome
  | [], _ => .served
  | w :: ws, r =>
    match w r with
    | .serve => .served
    | .refuse => .refused
    | .pass => runWrappers ws r

theorem before_depends_on_order :
    runWrappers [workflowWrapper, chatWrapperBefore] .workflow = .served ∧
    runWrappers [chatWrapperBefore, workflowWrapper] .workflow = .refused := by
  decide

theorem after_order_independent (r : Route) :
    runWrappers [workflowWrapper, chatWrapperAfter] r = runWrappers [chatWrapperAfter, workflowWrapper] r := by
  cases r <;> decide

theorem after_serves_both (r : Route) : runWrappers [chatWrapperAfter, workflowWrapper] r = .served := by
  cases r <;> decide

end DispatchOrder
end SyrusModel
