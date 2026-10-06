require "rails_helper"

RSpec.describe RecordsStateTransitions, :ci_only do
  describe "#state_changed_in_transaction?" do
    # The bug this exists to prevent: `after_update_commit ... if:
    # saved_change_to_state?` reads dirty tracking, which reflects only the
    # most recent save. Anything that rewrites or reloads the record partway
    # through the commit-callback chain resets it, and every callback defined
    # after that point then sees `saved_change_to_state? == false` and is
    # silently skipped.
    #
    # On Job that happens for real: `enqueue_deferred_visual_diff_work_after_implementation`
    # calls VisualDiffSubmission.enqueue_deferred_for_job, which reloads the
    # Job, so the callbacks behind it in the chain -- including
    # `start_dependent_jobs_after_implementation` -- lost their guard and
    # dependents never started when the parent reached :implemented.
    it "stays true for the whole commit chain even after a callback reloads the record" do
      job = Factories.job_record
      job.update!(branch_name: "syrus/parent", pr_number: 4242)
      job.start_running!

      observed = []
      job.define_singleton_method(:saved_change_to_implemented?) do
        # Let the real chain run: the reload that clears dirty tracking happens
        # inside one of these very callbacks, so suppressing them would hide it.
        guard = super()
        observed << { guard: guard, dirty_tracking: saved_change_to_state? }
        guard
      end

      job.mark_implemented!

      expect(observed).not_to be_empty
      # Confirms the hazard is still live rather than that the spec got lucky:
      # some callback in the chain does clear dirty tracking.
      expect(observed.map { _1[:dirty_tracking] }).to include(false)
      # ...and the guard holds anyway, because it asks the state machine.
      expect(observed.map { _1[:guard] }).to all(be(true))
    end

    it "is false when the transaction did not change state" do
      job = Factories.job_record

      observed = nil
      job.define_singleton_method(:state_changed_in_transaction?) do
        observed = super()
      end

      job.update!(branch_name: "syrus/renamed")

      expect(observed).to be(false)
    end
  end

  describe "clearing" do
    # Cleared from `committed!` rather than an `after_commit` callback so it
    # cannot land before the guards read it. If it leaked past the commit, a
    # later unrelated write to the same in-memory record would re-fire every
    # state-change hook.
    it "forgets the transition once the transaction has committed" do
      job = Factories.job_record
      job.update!(branch_name: "syrus/parent", pr_number: 4242)
      job.start_running!

      expect(job.recorded_state_transitions).to be_empty
    end

    it "records the transition while the transaction is still open" do
      job = Factories.job_record
      recorded = nil

      Job.transaction do
        job.start_running!
        recorded = job.recorded_state_transitions.dup
      end

      expect(recorded).to eq(%w[running])
    end
  end
end
