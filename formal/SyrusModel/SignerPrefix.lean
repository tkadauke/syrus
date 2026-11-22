/-!
# A plugin's signer owns its name prefix

A publisher in a registry trust store may own one name prefix. The registry
listing (`PluginRegistryClient#parse_entries`) accepts an entry only when the
publisher it *declares* owns the entry's prefix. The detached signature names
its own key, and installation (`Syrus::PluginPackage::Verifier`) trusted any key
in the trust store. So a package signed by publisher B, listed under publisher
A's prefix, installed with B's trust label.

Invariant: an installed registry release's signer owns the name prefix. A
local upload signed by a publisher that declares a prefix is held to it.

The model is finite: three prefixes, publishers own an optional prefix.
-/

namespace SyrusModel
namespace SignerPrefix

abbrev Prefix := Fin 3

/-- A publisher's owned prefix, if it declares one. -/
abbrev Publisher := Option Prefix

/-- Installation's verdict before the fix: any trusted signer passes. -/
def acceptsBefore (_local : Bool) (_signer : Publisher) (_name : Prefix) : Bool := true

/-- `Verifier#owns_name?`. -/
def acceptsAfter (isLocal : Bool) (signer : Publisher) (name : Prefix) : Bool :=
  if isLocal then signer.all (· == name) else signer == some name

/-- The listing's rule for the publisher an entry declares. -/
def listed (declared : Publisher) (name : Prefix) : Bool := declared == some name

/-- Before: a signer that owns another prefix installs a listed registry entry. -/
theorem before_admits_foreign_signer :
    listed (some 0) 0 = true ∧ acceptsBefore false (some 1) 0 = true := by decide

/-- After: an accepted registry install is signed by the prefix's owner, the
same rule the listing applies to the declared publisher. -/
theorem after_registry_signer_owns_prefix :
    ∀ (s : Publisher) (n : Prefix), acceptsAfter false s n = true ↔ listed s n = true := by
  intro s; cases s with
  | none => decide
  | some p => revert p; decide

/-- After: a local upload is rejected exactly when its signer declares a
different prefix. -/
theorem after_local_respects_declared_prefix :
    ∀ (s : Publisher) (n : Prefix), acceptsAfter true s n = false ↔ ∃ p, s = some p ∧ p ≠ n := by
  intro s; cases s with
  | none => intro n; simp [acceptsAfter]
  | some q => simp only [Option.some.injEq, exists_eq_left']; revert q; decide

end SignerPrefix
end SyrusModel
