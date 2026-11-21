/-!
# DOC-44 Phase 4: a rule's scope and constraints never match a broader invocation

DOC-44: "Scope normalization cannot broaden authority."

`Permissions::PolicyRule#match_status` matches a rule against an invocation:
same capability and operation (when the rule names them), every selector equal,
every constraint satisfied, and the invocation's normalized resource scope
`equal` to or `narrower` than the rule's (`ResourceScopeSchema#compare`
normalizes both sides and fails closed on any error). A rule with no resource
scope is family-wide; an allow that broad is capped separately by the
descriptor's breadth ceiling (`PolicyEvaluator`). A `string_prefix` constraint
compares whitespace tokens, not raw text.

Model: a scope is the set of resources it covers, `compare` is set inclusion.
Proved: a matching rule covers every resource of the invocation
(`match_within_scope`), and a token-prefix constraint matches only when the
rule's tokens are a prefix of the invocation's tokens, so `git commit` does not
match `git commitfoo` (`prefix_tokens`, `no_raw_text_prefix`). The guarantee
rests on each provider's normalize and compare callbacks being correct for
their scope type. No bug found.
-/

namespace SyrusModel
namespace ScopeMatching

/-- A scope as the list of resources it covers. -/
abbrev Scope := List Nat

def within (inner outer : Scope) : Bool := inner.all (outer.contains ·)

/-- `match_status` for the scope part: no rule scope matches everything. -/
def scopeMatches (rule : Option Scope) (invocation : Scope) : Bool :=
  match rule with
  | none => true
  | some s => within invocation s

theorem match_within_scope (s : Scope) (inv : Scope) (h : scopeMatches (some s) inv = true) :
    ∀ r ∈ inv, r ∈ s := by
  intro r hr
  have := List.all_eq_true.mp h r hr
  simpa using this

/-- `token_prefix?` -/
def tokenPrefix (expected actual : List String) : Bool :=
  !expected.isEmpty && !actual.isEmpty && actual.take expected.length == expected

theorem prefix_tokens (e a : List String) (h : tokenPrefix e a = true) : e <+: a := by
  simp only [tokenPrefix, Bool.and_eq_true, Bool.not_eq_true', beq_iff_eq] at h
  rw [← h.2]
  exact List.take_prefix _ _

theorem no_raw_text_prefix : tokenPrefix ["git", "commit"] ["git", "commitfoo"] = false := by decide

end ScopeMatching
end SyrusModel
