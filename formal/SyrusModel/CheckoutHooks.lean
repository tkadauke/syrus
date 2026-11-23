/-!
# A post-checkout hook the branch added never runs unasked (NY23, decided A)

`syrus checkout` runs `hooks.post_checkout` from the checked-out branch's
`.syrus.yml` on the reviewer's machine. A Job branch is written by an agent
working from issue text, so on a repository that accepts outside issues the
issue author could steer the agent into adding a hook. Before NY23 every hook
ran unless the Job was an external PR.

Now a hook runs without asking only when its Job kind is one Syrus writes
(issue, direct, cron) and the same command is in the same `.syrus.yml` on the
base branch. Any other hook runs only after the operator consents: a yes at the
prompt, or `--hooks`.
-/

namespace SyrusModel
namespace CheckoutHooks

inductive Kind where
  | issue | direct | cron | externalPr | other | missing
  deriving DecidableEq, Repr

def knownKind : Kind → Bool
  | .issue | .direct | .cron => true
  | _ => false

structure Hook where
  kind : Kind
  onBase : Bool
  consent : Bool
  deriving DecidableEq, Repr

/-- Before: everything but an external PR ran. -/
def runsBefore (h : Hook) : Bool := h.kind != .externalPr

/-- After: `postCheckoutHooksAllowed` and the base-branch trust check. -/
def runsAfter (h : Hook) : Bool := knownKind h.kind && (h.onBase || h.consent)

def hooks : List Hook :=
  [.issue, .direct, .cron, .externalPr, .other, .missing].flatMap fun k =>
    [true, false].flatMap fun b => [true, false].map fun c => ⟨k, b, c⟩

/-- Before: an agent-added hook on an issue Job ran with no consent. -/
theorem before_runs_agent_hook : runsBefore ⟨.issue, false, false⟩ = true := by decide

/-- Before: an unknown or missing kind ran hooks too. -/
theorem before_runs_unknown_kind : runsBefore ⟨.missing, true, false⟩ = true := by decide

/-- After: a hook runs without consent only if it is already on the base branch. -/
theorem after_unasked_only_if_on_base : ∀ h ∈ hooks, runsAfter h = true → h.consent = false → h.onBase = true := by
  decide

/-- After: unknown kinds fail closed, whatever the operator says. -/
theorem after_unknown_kind_never_runs : ∀ h ∈ hooks, knownKind h.kind = false → runsAfter h = false := by decide

end CheckoutHooks
end SyrusModel
