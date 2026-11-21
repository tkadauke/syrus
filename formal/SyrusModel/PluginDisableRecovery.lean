/-!
# DOC-44 plugin host: disabling a plugin never strands its active work

DOC-44: "Disabling a plugin never leaves work that cannot be finished or
cancelled."

A plugin's `:workflow_kinds` contributions (trigger kinds, step kinds, Job
kinds) are installed into the kind registries while it is enabled and torn
down when it is not. Two things went wrong when an operator disabled a plugin
with work of its kinds in flight:

* `Job`, `Workflow`, `Step` and `Run` validated their unchanged kind against
  the *current* registry on every save, so every save of an existing row,
  cancellation included, raised `RecordInvalid` (`stranded_before`).
* `Admin::PluginDisableGuard` had no blocker for that work, so nothing stopped
  the disable. Even with saves fixed, `Workflow#work_definition` and the step
  handler resolve through the registry and are gone with the plugin.

After the fix:

* kind inclusion is checked only on create and on a kind change
  (`existing_saves`), while a new row or a changed kind still has to name an
  installed kind (`new_rows_checked`);
* the guard refuses to disable a plugin while a queued or running workflow of
  its trigger kinds, or step of its step kinds, exists. So in every reachable
  state, every active row's kind is installed (`active_kinds_installed`):
  disabling preserves the invariant because it is guarded, and creating or
  re-kinding a row preserves it because of the validation.

Health degradation also withholds a plugin's providers, kinds included, and no
operator action is there to guard; that path is queued as NY14.
-/

namespace SyrusModel
namespace PluginDisableRecovery

/-- Kinds are owned by plugins `0..n-1`; kind `k` belongs to plugin `k % n`. -/
structure Row where
  kind : Nat
  active : Bool
deriving DecidableEq, Repr

structure State where
  enabled : List Bool
  rows : List Row
deriving DecidableEq, Repr

def owner (n k : Nat) : Nat := k % n

def installed (n : Nat) (s : State) (k : Nat) : Bool := s.enabled.getD (owner n k) false

/-- Before: validation ran against the live registry on every save. -/
def saveOkBefore (n : Nat) (s : State) (r : Row) : Bool := installed n s r.kind

/-- After: an unchanged kind is not rechecked. -/
def saveOk (_n : Nat) (_s : State) (_r : Row) (kindChanged : Bool) (newKindInstalled : Bool) : Bool :=
  !kindChanged || newKindInstalled

def guardAllows (n : Nat) (s : State) (p : Nat) : Bool :=
  s.rows.all (fun r => !(r.active && owner n r.kind == p))

inductive Action where
  | disable (p : Nat)
  | enable (p : Nat)
  | create (k : Nat)
  | finish (i : Nat)
deriving Repr

def setAt (l : List Bool) (i : Nat) (v : Bool) : List Bool :=
  (List.range l.length).map (fun j => if j = i then v else l.getD j false)

/-- One guarded transition (a refused action leaves the state unchanged). -/
def apply (n : Nat) (s : State) : Action → State
  | .disable p => if guardAllows n s p then { s with enabled := setAt s.enabled p false } else s
  | .enable p => { s with enabled := setAt s.enabled p true }
  | .create k => if installed n s k then { s with rows := s.rows ++ [⟨k, true⟩] } else s
  | .finish i => { s with rows := (List.range s.rows.length).map (fun j =>
      let r := s.rows.getD j ⟨0, false⟩; if j = i then { r with active := false } else r) }

def invariant (n : Nat) (s : State) : Bool :=
  s.rows.all (fun r => !r.active || installed n s r.kind)

def actions (n kinds rows : Nat) : List Action :=
  (List.range n).map .disable ++ (List.range n).map .enable ++
  (List.range kinds).map .create ++ (List.range rows).map .finish

def run (n : Nat) (s : State) : List Action → State
  | [] => s
  | a :: as => run n (apply n s a) as

def seqs (as : List Action) : Nat → List (List Action)
  | 0 => [[]]
  | k + 1 => (seqs as k).flatMap (fun xs => as.map (fun a => xs ++ [a]))

/-- From an empty start with every plugin enabled, every sequence of up to
    five guarded actions over two plugins and four kinds keeps every active
    row's kind installed. -/
def check : Bool :=
  let n := 2
  let start : State := ⟨[true, true], []⟩
  (List.range 6).all (fun len => (seqs (actions n 4 3) len).all (fun as => invariant n (run n start as)))

theorem active_kinds_installed : check = true := by native_decide

/-- The guard is what holds it: an unguarded disable with a running row of the
    plugin's kind breaks the invariant. -/
theorem unguarded_disable_strands :
    let s : State := ⟨[true, true], [⟨1, true⟩]⟩
    invariant 2 s = true ∧ invariant 2 { s with enabled := setAt s.enabled 1 false } = false ∧
      apply 2 s (.disable 1) = s := by
  decide

/-- Before: a disabled plugin's running row could not even be cancelled. -/
theorem stranded_before :
    saveOkBefore 2 ⟨[true, false], [⟨1, true⟩]⟩ ⟨1, true⟩ = false := by decide

/-- After: saving an existing row with its kind unchanged always succeeds. -/
theorem existing_saves (n : Nat) (s : State) (r : Row) (b : Bool) : saveOk n s r false b = true := by
  simp [saveOk]

/-- After: a new or changed kind still has to be installed. -/
theorem new_rows_checked (n : Nat) (s : State) (r : Row) : saveOk n s r true false = false := by
  simp [saveOk]

end PluginDisableRecovery
end SyrusModel
