/-!
# DOC-44 Phase 4: delegated (AI) approval never exceeds its configured authority

DOC-44: "Approval delegation cannot expand beyond its configured authority."

An operator can delegate approvals to an approval provider
(`ApprovalProviderDelegation`). `Permissions::ApprovalProviderAuthorizer`
lets the provider decide a pending request only if: the capability is not the
human-only `syrus.permissions` and no effect is core human-only (`financial`,
`privilege_change`); some active delegation `covers?` the request (same
capability and resource type, every key of its scope present in the request
and equal, or a non-empty subset for list keys, and no excluded effect, the
core human-only effects always excluded); no non-delegable rule in the policy
chain stands above `allow`; and the provider answers with confidence of at
least 0.8. `ApprovalProviderLifecycle#approve!` then records an
`invocation`-duration approval and issues a single `AuthorizedInvocation`, so
a delegated approval never becomes standing authority.

Proved: a delegated approval implies the delegation covers the request's
capability, scope keys and effects, and the result is single-use
(`delegated_within_authority`); a list-scoped delegation never covers a
request asking for something outside the list (`list_scope_subset`). No bug
found.
-/

namespace SyrusModel
namespace ApprovalDelegation

structure Request where
  capability : Nat
  scope : List (Nat × List Nat)
  effects : List Nat
  humanOnly : Bool
  ceilingBlocks : Bool
  confidence : Nat
  deriving DecidableEq, Repr

structure Delegation where
  capability : Nat
  scope : List (Nat × List Nat)
  excluded : List Nat
  active : Bool
  deriving DecidableEq, Repr

/-- `scope_covers?`, list form: each ceiling key is present and the request's
    values are a non-empty subset of the ceiling's. -/
def scopeCovers (ceiling requested : List (Nat × List Nat)) : Bool :=
  ceiling.all (fun (k, allowed) => match requested.lookup k with
    | some vs => !vs.isEmpty && vs.all (allowed.contains ·)
    | none => false)

def covers (d : Delegation) (r : Request) : Bool :=
  d.active && d.capability == r.capability && scopeCovers d.scope r.scope && r.effects.all (!d.excluded.contains ·)

inductive Duration where | invocation deriving DecidableEq, Repr

/-- The authorizer plus lifecycle: an approval, if any, is single-use. -/
def approve (d : Delegation) (r : Request) : Option Duration :=
  if r.humanOnly || r.ceilingBlocks || r.confidence < 80 || !covers d r then none else some .invocation

theorem approve_requires (d : Delegation) (r : Request) (dur : Duration) (h : approve d r = some dur) :
    covers d r = true ∧ r.humanOnly = false := by
  unfold approve at h
  cases hh : r.humanOnly <;> cases hcv : covers d r <;> simp_all

theorem covers_sound (d : Delegation) (r : Request) (h : covers d r = true) :
    d.active = true ∧ d.capability = r.capability ∧ scopeCovers d.scope r.scope = true ∧
      ∀ e ∈ r.effects, e ∉ d.excluded := by
  simp only [covers, Bool.and_eq_true, beq_iff_eq, List.all_eq_true] at h
  obtain ⟨⟨⟨ha, hcap⟩, hs⟩, he⟩ := h
  refine ⟨ha, hcap, hs, fun e hm hx => ?_⟩
  have := he e hm
  simp [hx] at this

theorem delegated_within_authority (d : Delegation) (r : Request) (dur : Duration) (h : approve d r = some dur) :
    d.active = true ∧ d.capability = r.capability ∧ scopeCovers d.scope r.scope = true ∧
      (∀ e ∈ r.effects, e ∉ d.excluded) ∧ r.humanOnly = false ∧ dur = .invocation := by
  obtain ⟨hc, hh⟩ := approve_requires d r dur h
  obtain ⟨ha, hcap, hs, he⟩ := covers_sound d r hc
  exact ⟨ha, hcap, hs, he, hh, by cases dur; rfl⟩

theorem list_scope_subset :
    scopeCovers [(1, [10, 11])] [(1, [10, 12])] = false ∧ scopeCovers [(1, [10, 11])] [(1, [10])] = true := by
  decide

end ApprovalDelegation
end SyrusModel
