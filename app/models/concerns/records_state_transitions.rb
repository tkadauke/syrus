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

  def record_state_transition!
    # Calling aasm during an after-callback gives us the state
    # machine's view of the transition that just ran. AASM's
    # after_all_transitions fires for every event regardless of
    # success — guard against transitions that no-op'd (from == to).
    machine = aasm
    from = machine.from_state.to_s
    to   = machine.to_state.to_s
    return if from == to

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
