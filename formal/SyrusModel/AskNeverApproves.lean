/-!
# DOC-44 Phase 4: an "ask" decision never runs the effect without a confirmation

DOC-44: "Ask never becomes implicit approval"; "Deny, allow, and ask precedence
follows the declared policy"; "Plugin-contributed capabilities cannot bypass
the evaluator."

`Permissions::PolicyEvaluator` decides `allow`, `ask` or `deny`. Any matching
deny in any layer wins, matching and scope-normalization failures fail closed,
over-broad allows are dropped, and non-delegable rules cap the result. The MCP
gate (`Mcp::Tools::AuthorizationSupport.authorization_gate`) then acts on the
decision on three paths:

* scheduled runs (`ScheduledAuthorization`): `allow` runs the tool; `deny`,
  and every routing outcome of `ask` (created, reused, cooldown, cap), return a
  response instead of running it;
* operator and coworker chats (`AuthorizationRequest`): `deny` raises; `allow`
  runs; `ask` always yields a request (an equivalent existing one or a new one),
  and the gate runs the tool only when there is none;
* tools whose effect *is* the owner's confirmation card (`approval_effect`,
  or a tool registered as a pending action): `deny` raises, and `ask` lets the
  tool run because what it does is create that card.

Proved: on every path, the effect runs on `ask` only for a tool whose effect is
a confirmation card (`ask_runs_only_confirmation_tools`); a deny never runs it
(`deny_never_runs`). No bug found. The trust boundary: `approval_effect` is a
declaration, and a plugin tool definition can declare it (NY12).
-/

namespace SyrusModel
namespace AskNeverApproves

inductive Policy where | allow | ask | deny deriving DecidableEq, Repr

inductive Path where | scheduled | chat | confirmationTool deriving DecidableEq, Repr

/-- What `AuthorizationRequest#call` returns on `ask`: an existing
    equivalent request or a new one, never none. -/
def requestOnAsk : Bool := true

/-- Whether the gate lets the tool body run. -/
def runs : Path → Policy → Bool
  | _, .deny => false
  | _, .allow => true
  | .scheduled, .ask => false
  | .chat, .ask => !requestOnAsk
  | .confirmationTool, .ask => true

theorem deny_never_runs (p : Path) : runs p .deny = false := by cases p <;> rfl

theorem ask_runs_only_confirmation_tools (p : Path) (h : runs p .ask = true) : p = .confirmationTool := by
  cases p <;> simp_all [runs, requestOnAsk]

/-- Precedence: a deny in any layer is decisive. -/
def combine (layers : List Policy) (innermost : Policy) : Policy :=
  if layers.contains .deny then .deny else innermost

theorem any_deny_wins (layers : List Policy) (inner : Policy) (h : Policy.deny ∈ layers) :
    combine layers inner = .deny := by
  simp [combine, h]

end AskNeverApproves
end SyrusModel
