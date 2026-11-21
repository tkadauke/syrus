/-!
# DOC-44 Phase 4: a permission lease authorizes only within its grant

DOC-44: "Leases cannot cross actors, resources, or instances"; "Expired or
revoked authority cannot start a new effect".

`Permissions::LeaseAuthorizer` loads the owner's leases for the capability and
operation (`PermissionLease.for_invocation`: not revoked, not expired, uses
remaining) under a row lock, keeps those `available?` for this invocation and
consumes the decisive one in the same transaction. `available?` requires: not
revoked, not expired, uses remaining, every effect of the invocation granted,
the constraints matched, and the duration's instance: the exact invocation
fingerprint (one use), the same live chat session, or the same non-terminal Job.
The lease then enters the policy evaluator as a rule carrying its subject
selector and resource scope, so a different actor or resource does not match
it.

Proved: an available lease is unrevoked, unexpired, has uses left, covers the
invocation's effects and belongs to the caller's instance (`available_sound`).
Consuming under the lock never exceeds `max_uses` (`consume_bounded`). No bug
found. A Job-scoped lease becomes usable again if its closed Job is reopened
(same thread, same grant); recorded in M10.
-/

namespace SyrusModel
namespace LeaseScope

inductive Instance where
  | invocation (fingerprint : Nat)
  | chat (id : Nat)
  | job (id : Nat)
  deriving DecidableEq, Repr

structure Lease where
  revoked : Bool
  expiresAt : Option Nat
  used : Nat
  maxUses : Option Nat
  effects : List Nat
  inst : Instance
  deriving DecidableEq, Repr

structure Call where
  now : Nat
  effects : List Nat
  fingerprint : Nat
  chat : Option Nat
  job : Option Nat
  /-- The chat is live / the Job is not terminal. -/
  instanceLive : Bool
  deriving DecidableEq, Repr

def usesLeft (l : Lease) : Bool := match l.maxUses with | none => true | some m => l.used < m

def instanceMatches (l : Lease) (c : Call) : Bool :=
  match l.inst with
  | .invocation f => f == c.fingerprint
  | .chat id => c.instanceLive && c.chat == some id
  | .job id => c.instanceLive && c.job == some id

/-- `PermissionLease#available?` -/
def available (l : Lease) (c : Call) : Bool :=
  !l.revoked && (match l.expiresAt with | none => true | some e => c.now < e) && usesLeft l &&
    c.effects.all (l.effects.contains ·) && instanceMatches l c

theorem available_sound (l : Lease) (c : Call) (h : available l c = true) :
    l.revoked = false ∧ (∀ e, l.expiresAt = some e → c.now < e) ∧ usesLeft l = true ∧
      (∀ x ∈ c.effects, x ∈ l.effects) ∧ instanceMatches l c = true := by
  simp only [available, Bool.and_eq_true, Bool.not_eq_true', List.all_eq_true] at h
  obtain ⟨⟨⟨⟨hr, he⟩, hu⟩, hf⟩, hi⟩ := h
  refine ⟨hr, fun e hx => ?_, hu, fun x hx => ?_, hi⟩
  · rw [hx] at he; simpa using he
  · simpa using hf x hx

/-- `consume!` under the row lock: only when uses remain. -/
def consume (l : Lease) : Option Lease := if usesLeft l then some { l with used := l.used + 1 } else none

theorem consume_bounded (l : Lease) (l' : Lease) (m : Nat) (hm : l.maxUses = some m)
    (h : consume l = some l') : l'.used ≤ m := by
  unfold consume usesLeft at h
  rw [hm] at h
  by_cases hc : l.used < m
  · simp only [hc, decide_true, if_true, Option.some.injEq] at h; subst h; simp; omega
  · simp [hc] at h

end LeaseScope
end SyrusModel
