/-!
# DOC-44 Phase 4: an approved invocation runs at most once, under fresh authority

DOC-44: "Authorization is committed when the external effect becomes possible,
not merely when requested"; "Retries and resumed work obtain fresh authority
when required"; "Expired or revoked authority cannot start a new effect".

An approved tool call becomes an `AuthorizedInvocation` in state `issued`.
`PendingActions::AuthorizedToolCall` executes it by claiming it
(`AuthorizedInvocation#claim!`, under the row lock): only an `issued`
invocation can be claimed; the arguments' fingerprint must equal the approved
one (else it is invalidated); the originating action must still be confirming;
and authority is re-evaluated at claim time (`revalidate_authority`), so a
revoked or narrowed grant refuses it. The tool gate
(`claimed_invocation_authorizes?`) then requires the same claim key, claimant,
tool and fingerprint. Revoking the authority invalidates every unclaimed
invocation.

Proved: a claim succeeds only from `issued`, with a matching fingerprint and
current authority (`claim_requires`), and a claimed invocation cannot be
claimed again (`claim_once`). No bug found.
-/

namespace SyrusModel
namespace InvocationClaim

inductive State where | issued | claimed | succeeded | failed | invalidated deriving DecidableEq, Repr

structure Inv where
  state : State
  fingerprint : Nat
  deriving DecidableEq, Repr

structure Attempt where
  fingerprint : Nat
  originResumable : Bool
  authorityHolds : Bool
  deriving DecidableEq, Repr

/-- `claim_under_lock!`: the new state, and whether the claim succeeded. -/
def claim (i : Inv) (a : Attempt) : Inv × Bool :=
  if i.state != .issued then (i, false)
  else if a.fingerprint != i.fingerprint then ({ i with state := .invalidated }, false)
  else if !a.originResumable then ({ i with state := .invalidated }, false)
  else if !a.authorityHolds then ({ i with state := .invalidated }, false)
  else ({ i with state := .claimed }, true)

theorem claim_requires (i : Inv) (a : Attempt) (h : (claim i a).2 = true) :
    i.state = .issued ∧ a.fingerprint = i.fingerprint ∧ a.originResumable = true ∧ a.authorityHolds = true := by
  unfold claim at h
  by_cases h1 : i.state = .issued <;> by_cases h2 : a.fingerprint = i.fingerprint <;>
    cases ho : a.originResumable <;> cases hauth : a.authorityHolds <;> simp_all

theorem claim_once (i : Inv) (a b : Attempt) (h : (claim i a).2 = true) : (claim (claim i a).1 b).2 = false := by
  have := (claim_requires i a h)
  obtain ⟨h1, h2, h3, h4⟩ := this
  simp [claim, h1, h2, h3, h4]

end InvocationClaim
end SyrusModel
