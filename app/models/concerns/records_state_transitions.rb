module RecordsStateTransitions
  extend ActiveSupport::Concern

  # Mixed in by Job/Workflow/Step/Run. The host class registers
  # the AASM after-callback INSIDE its `aasm do ... end` block:
  #
  #   aasm column: :state, whiny_transitions: false do
  #     after_all_transitions :record_state_transition!
  #     state :queued, initial: true
  #     ...
  #   end
  #
  # The callback uses aasm.from_state / to_state / current_event so
  # we capture the actual transition that fired (not just the
  # current state, which would lose the "from" half).
  #
  # Source defaults to "aasm" — wrap callsites in
  # StateTransition.with_source("propagate" / "reconciler" / "operator")
  # to override.

  # Dirty tracking is not a reliable record of "this commit changed state".
  # `saved_changes` describes only the most recent save, and anything that writes
  # or reloads the record resets it -- including code running inside the
  # commit-callback chain itself. Every `after_*_commit ... if:
  # saved_change_to_state?` guard registered *after* that point then evaluates
  # false and its callback is silently skipped, even though the state genuinely
  # did change in that transaction.
  #
  # Measured on Job reaching :implemented: the guard is true for the first two
  # callbacks in the chain, then `enqueue_deferred_visual_diff_work_after_implementation`
  # calls VisualDiffSubmission.enqueue_deferred_for_job, which reloads the Job,
  # and the remaining four evaluations see false. One of the callbacks behind it
  # is `start_dependent_jobs_after_implementation`, so dependent Jobs were not
  # started when their parent reached :implemented.
  #
  # The order is incidental and the hazard is not: any callback that writes or
  # reloads disarms every guard behind it. The state machine knows what happened
  # regardless of how the row was subsequently written or re-read, so record it
  # here and let the commit guards ask this instead of asking dirty tracking.

  # States this instance transitioned into during the current transaction.
  def recorded_state_transitions
    @recorded_state_transitions ||= []
  end

  def transitioned_to_in_transaction?(state_name)
    recorded_state_transitions.include?(state_name.to_s)
  end

  # True when the state changed in this transaction, whether or not the last
  # save to this record happened to be the one that changed it.
  def state_changed_in_transaction?
    saved_change_to_state? || recorded_state_transitions.any?
  end

  # Cleared from `committed!`/`rolledback!` rather than from an `after_commit`
  # callback: callback order between a concern and its including class depends on
  # both include order and `run_after_transaction_callbacks_in_order_defined`, and
  # a clear that lands before the guards read it would reintroduce the bug it
  # exists to fix. These two methods are what run the commit callbacks, so
  # clearing in their `ensure` is after all of them by construction.
  def committed!(...)
    super
  ensure
    clear_recorded_state_transitions!
  end

  def rolledback!(...)
    super
  ensure
    clear_recorded_state_transitions!
  end

  def clear_recorded_state_transitions!
    @recorded_state_transitions = []
  end

  def record_state_transition!
    # Calling aasm during an after-callback gives us the state
    # machine's view of the transition that just ran. AASM's
    # after_all_transitions fires for every event regardless of
    # success — guard against transitions that no-op'd (from == to).
    machine = aasm
    from = machine.from_state.to_s
    to   = machine.to_state.to_s
    return if from == to

    recorded_state_transitions << to

    reason_key = StateTransition.reason_key_for(self)
    metadata = StateTransition.transition_metadata_for(self)
    metadata["reason_key"] = reason_key if reason_key.present?

    StateTransition.create!(
      subject: self,
      from_state: from,
      to_state: to,
      event_name: machine.current_event.to_s.chomp("!"),
      source: StateTransition.current_source,
      user_id: StateTransition.current_user&.id,
      run_id: StateTransition.current_run_id,
      metadata: metadata
    )
  rescue StandardError => e
    # An audit-write failure must not roll back the state machine.
    # The transition still happened; we just don't have a record.
    Rails.logger.warn(
      "[state_transition] failed to record #{self.class.name}##{id} " \
      "#{aasm.from_state} → #{aasm.to_state}: #{e.class}: #{e.message}"
    )
  end
end
