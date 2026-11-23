/-!
# approval_effect is honoured only when a confirmation card backs it (NY12, decided A)

A tool marked `approval_effect` skips the generic "ask" request, because its
only mutation is creating the owner's confirmation card; policy still runs and
a deny still refuses it. For a core tool the flag comes from `McpToolRegistry`.
A plugin's tool-set definition could also set it, and nothing checked that the
tool really creates a card, so a plugin tool could declare it and run on "ask"
with no confirmation.

`AuthorizationSupport.approval_effect_backed?` now honours a plugin's flag
only when the plugin registers a pending action under the tool's name; the
Coworkers spawn tools register `spawn_coworker_chat` and `spawn_syrus_chat`
and create their cards as those actions.

Invariant: on "ask", a tool runs without a generic request only if its effect
is backed: a core tool, or a registered card.
-/

namespace SyrusModel
namespace ApprovalEffectBacking

structure Tool where
  core : Bool
  claimsEffect : Bool
  registeredCard : Bool
  deriving DecidableEq, Repr

/-- Whether the generic ask is skipped, before the fix. -/
def skipsBefore (t : Tool) : Bool := t.claimsEffect

/-- `approval_effect_backed?`. -/
def skipsAfter (t : Tool) : Bool := t.claimsEffect && (t.core || t.registeredCard)

def backed (t : Tool) : Bool := t.core || t.registeredCard

def tools : List Tool :=
  [true, false].flatMap fun c => [true, false].flatMap fun e => [true, false].map fun r => ⟨c, e, r⟩

/-- Before: a plugin tool with a bare claim skipped the ask. -/
theorem before_bare_claim_skips : skipsBefore ⟨false, true, false⟩ = true ∧ backed ⟨false, true, false⟩ = false := by
  decide

/-- After: the ask is skipped only for a backed effect. -/
theorem after_skip_implies_backed : ∀ t ∈ tools, skipsAfter t = true → backed t = true := by decide

/-- After: every backed claim still skips, so the spawn tools keep one card. -/
theorem after_backed_claim_skips : ∀ t ∈ tools, t.claimsEffect = true → backed t = true → skipsAfter t = true := by
  decide

end ApprovalEffectBacking
end SyrusModel
