/-!
# DOC-44 plugin host: a rename never broadens authority

DOC-44: "Permission upgrades and scope migrations cannot broaden authority
unless the expansion is explicit."

A plugin may rename a capability or operation (`…@v1` to `…@v2`) and list the
old identifier in `capability_aliases` or `operation_aliases`.
`CapabilityUpgradeValidator` accepts that as the same capability, with no
widening, so no migration is needed. Stored permission rules keep the
identifier they were written with. `PolicyRule#match_status` compared those
identifiers literally, so after the rename an operator's rule for `@v1` stopped
matching `@v2` invocations. A deny then fell through to the default, which can
be allow (`rename_turned_deny_into_allow`).

After the fix (`PolicyRule#match_status` and `CapabilityDescriptor#names_*`
honour aliases), a rename that lists the old identifier as an alias changes no
decision. That holds for every list of up to three rules stored before the
rename, over the old and an unrelated identifier, and every policy, with deny over ask over allow, then the role
default (`rename_preserves_decisions`). A rule for an identifier the
descriptor never had still does not match (`foreign_rule_ignored`).
-/

namespace SyrusModel
namespace RuleAliases

inductive Policy where
  | allow | ask | deny
deriving DecidableEq, Repr

structure Rule where
  ident : Nat
  policy : Policy
deriving DecidableEq, Repr

/-- The descriptor an invocation is evaluated against. -/
structure Descriptor where
  canonical : Nat
  aliases : List Nat
deriving DecidableEq, Repr

def matchesBefore (d : Descriptor) (r : Rule) : Bool := r.ident == d.canonical

def matchesAfter (d : Descriptor) (r : Rule) : Bool := r.ident == d.canonical || d.aliases.contains r.ident

/-- Deny over ask over allow; otherwise the role default. -/
def decide' (hits : Rule → Bool) (default : Policy) (rules : List Rule) : Policy :=
  let hit := rules.filter hits
  if hit.any (·.policy == .deny) then .deny
  else if hit.any (·.policy == .ask) then .ask
  else if hit.any (·.policy == .allow) then .allow
  else default

def policies : List Policy := [.allow, .ask, .deny]

def rules : List Rule := [0, 1, 2].flatMap (fun i => policies.map (fun p => ⟨i, p⟩))

def ruleLists : Nat → List (List Rule)
  | 0 => [[]]
  | k + 1 => [] :: (ruleLists k).flatMap (fun rs => rules.map (fun r => r :: rs))

/-- Before the rename the operation is `0`; after, it is `1` with alias `0`.
    Identifier `2` belongs to some other operation. Rules stored before the
    rename cannot name `1`: it is fresh, and the validator forbids reusing a
    retired identifier. -/
def check : Bool :=
  ((ruleLists 3).filter (fun rs => rs.all (·.ident != 1))).all (fun rs => policies.all (fun dflt =>
    decide' (matchesAfter ⟨1, [0]⟩) dflt rs == decide' (matchesBefore ⟨0, []⟩) dflt rs))

theorem rename_preserves_decisions : check = true := by native_decide

/-- Before the fix: a stored deny for `@v1` stops applying to `@v2`, and the
    allow default decides. -/
theorem rename_turned_deny_into_allow :
    decide' (matchesBefore ⟨0, []⟩) .allow [⟨0, .deny⟩] = .deny ∧
      decide' (matchesBefore ⟨1, [0]⟩) .allow [⟨0, .deny⟩] = .allow := by
  decide

theorem foreign_rule_ignored :
    decide' (matchesAfter ⟨1, [0]⟩) .allow [⟨2, .deny⟩] = .allow := by
  decide

end RuleAliases
end SyrusModel
