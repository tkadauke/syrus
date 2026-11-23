/-!
# The required-review HEAD barrier

`Workflows::ImmutableReviewHeadBarrier` lets downstream work run only when every
required review approved the *tracked* HEAD: the `head_sha` of the latest
succeeded `implement`/`respond` Run (`MUTATION_KINDS`). A tracked mutation also
re-materializes the required reviews for the new HEAD.

The property operators expect: **whatever is pushed was approved by every
required review.** We model a Workflow as a sequence of steps acting on a
single HEAD (commits are numbered), and check the barrier's verdict at the push.

Step kinds, by how they move HEAD:
* `tracked` — `implement`/`respond`: moves HEAD and updates the tracked SHA.
* `mechanical` — `format`, `generate` (`.syrus.yml` formatters/generators):
  moves HEAD, not tracked.
* `agentUntracked` — `landing_fix`, agent rebases (`agent_rebase`,
  `merge_train_agent_rebase`, `merge_train_agent`): agent-authored, not tracked.
* `review` — approves the current tracked SHA.

The step-sequence model below has one way to pass (approval of the tracked
HEAD). The code has three; the `Evidence` section at the end models them, and
`formal/fixtures/review_barrier.json` checks that section against the Ruby.
-/

namespace SyrusModel
namespace ReviewBarrier

inductive Step where
  | tracked | mechanical | agentUntracked | review
  deriving DecidableEq, Repr

structure S where
  /-- Actual workspace HEAD (commit counter). -/
  head : Nat
  /-- `reviewed_head_sha`: HEAD as of the last tracked mutation, if any. -/
  tracked : Option Nat
  /-- HEADs a (single, for simplicity) required review approved. -/
  approved : List Nat
  /-- Last agent-authored HEAD (tracked or untracked). -/
  lastAgent : Nat
  deriving Repr

def S.init : S := ⟨0, none, [], 0⟩

def step (s : S) : Step → S
  | .tracked => { s with head := s.head + 1, tracked := some (s.head + 1), lastAgent := s.head + 1 }
  | .mechanical => { s with head := s.head + 1 }
  | .agentUntracked => { s with head := s.head + 1, lastAgent := s.head + 1 }
  | .review => match s.tracked with
      | some h => { s with approved := h :: s.approved }
      | none => { s with approved := s.head :: s.approved }

def run (s : S) : List Step → S
  | [] => s
  | x :: xs => run (step s x) xs

/-- `satisfied_for?` as written: vacuous without a tracked SHA, otherwise the
    tracked SHA must have been approved. -/
def barrier (s : S) : Bool :=
  match s.tracked with
  | none => true
  | some h => s.approved.contains h

/-- What operators expect at the push. -/
def pushedReviewed (s : S) : Bool := s.approved.contains s.head

/-- What the barrier actually guarantees when only mechanical steps are untracked. -/
def lastAgentReviewed (s : S) : Bool := s.approved.contains s.lastAgent

/-! ## Counterexamples -/

/-- A formatter or generator commit after approval is pushed unreviewed while the
    barrier passes. -/
theorem mechanical_after_review :
    let s := run S.init [.tracked, .review, .mechanical]
    barrier s = true ∧ pushedReviewed s = false ∧ lastAgentReviewed s = true := by decide

/-- An agent-authored landing fix or conflict resolution after approval is pushed
    unreviewed — and not even the last agent-authored commit was reviewed. -/
theorem agent_untracked_after_review :
    let s := run S.init [.tracked, .review, .agentUntracked]
    barrier s = true ∧ pushedReviewed s = false ∧ lastAgentReviewed s = false := by decide

/-- The fail-open (`sha.blank?` ⇒ satisfied) is only dangerous combined with an
    untracked move: with no tracked mutation and no untracked move, a review
    approves the HEAD that is pushed. -/
theorem vacuous_barrier_with_untracked :
    let s := run S.init [.review, .agentUntracked]
    barrier s = true ∧ pushedReviewed s = false := by decide

/-! ## What does hold -/

/-- Invariant over runs made only of tracked mutations and reviews: whenever the
    barrier passes, the current HEAD was approved. -/
def OnlyTracked : List Step → Prop
  | [] => True
  | x :: xs => (x = .tracked ∨ x = .review) ∧ OnlyTracked xs

theorem head_eq_tracked_of_onlyTracked :
    ∀ (xs : List Step) (s : S), (s.tracked = none → s.head = 0) → (∀ h, s.tracked = some h → h = s.head) →
      OnlyTracked xs →
      ((run s xs).tracked = none → (run s xs).head = 0) ∧ (∀ h, (run s xs).tracked = some h → h = (run s xs).head)
  | [], _, h0, h1, _ => ⟨h0, h1⟩
  | x :: xs, s, h0, h1, ⟨hx, hxs⟩ => by
    apply head_eq_tracked_of_onlyTracked xs (step s x) _ _ hxs
    · rcases hx with rfl | rfl
      · simp [step]
      · intro hn; cases ht : s.tracked with
        | none => simp [step, ht] at hn ⊢; exact h0 ht
        | some h => simp [step, ht] at hn
    · rcases hx with rfl | rfl
      · intro h hh; simp [step] at hh ⊢; omega
      · intro h hh
        cases ht : s.tracked with
        | none => simp [step, ht] at hh
        | some k => simp [step, ht] at hh ⊢; subst hh; exact h1 k ht

theorem tracked_only_push_reviewed (xs : List Step) (h : OnlyTracked xs)
    (hb : barrier (run S.init xs) = true) (hstarted : (run S.init xs).tracked.isSome = true) :
    pushedReviewed (run S.init xs) = true := by
  obtain ⟨_, h1⟩ := head_eq_tracked_of_onlyTracked xs S.init (by simp [S.init]) (by simp [S.init]) h
  cases ht : (run S.init xs).tracked with
  | none => simp [ht] at hstarted
  | some k =>
    have hk := h1 k ht
    simp [barrier, ht] at hb
    simp [pushedReviewed, ← hk, hb]

/-! ## The three ways a required review passes (Lead L12)

`satisfied_for?` accepts, for each required review of the tracked HEAD, any of:
succeeded evidence that approved that HEAD; a review that reacted without
changing HEAD (`reacted_without_head_change?`); or a recorded budget exhaustion
for that HEAD (`exhausted_for_head?`), which `record_budget_exhaustion!` writes
together with a high-severity workflow warning. Without a tracked HEAD the
barrier is vacuous (legacy and imported Workflows).

So "whatever is pushed was approved by every required review" holds only up to
the exhaustion exception: a pass is approval, a no-change reaction, or an
exhaustion that was recorded and warned for exactly that HEAD.
-/

/-- One required review's evidence about the tracked HEAD. -/
structure Evidence where
  tracked : Bool
  succeeded : Bool
  approved : Bool
  reactedWithoutHeadChange : Bool
  exhaustedForHead : Bool
  deriving DecidableEq, Repr

/-- `ImmutableReviewHeadBarrier.satisfied_for?` for one required review. -/
def satisfied (e : Evidence) : Bool :=
  !e.tracked || (e.succeeded && e.approved) || e.reactedWithoutHeadChange || e.exhaustedForHead

def allEvidence : List Evidence :=
  [true, false].flatMap fun t => [true, false].flatMap fun s => [true, false].flatMap fun a =>
    [true, false].flatMap fun r => [true, false].map fun x => ⟨t, s, a, r, x⟩

/-- A pass on a tracked HEAD is an approval, a no-change reaction, or the
recorded and warned exhaustion exception, and nothing else. -/
theorem pass_is_approval_reaction_or_exception :
    allEvidence.all (fun e => !(e.tracked && satisfied e) ||
      (e.succeeded && e.approved) || e.reactedWithoutHeadChange || e.exhaustedForHead) = true := by decide

/-- Without the exception, a pass on a tracked HEAD means it was approved or a
review reacted without changing it. -/
theorem pass_without_exception_is_reviewed :
    allEvidence.all (fun e => !(e.tracked && !e.exhaustedForHead && satisfied e) ||
      (e.succeeded && e.approved) || e.reactedWithoutHeadChange) = true := by decide

/-- The exception is what lets an unreviewed HEAD through. -/
theorem exhaustion_passes_unreviewed : satisfied ⟨true, false, false, false, true⟩ = true := by decide

end ReviewBarrier
end SyrusModel
