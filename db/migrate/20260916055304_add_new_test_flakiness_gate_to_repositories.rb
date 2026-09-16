class AddNewTestFlakinessGateToRepositories < ActiveRecord::Migration[8.1]
  # Opt-in: after required graders pass, rerun just the test files this Job's
  # diff touched (added or modified) a few more times to catch a test that is
  # flaky from day one -- Adjudicators::KnownFlakyFailure has no history to
  # work from for a test that has never run before. Off by default -- same
  # shape as known_flaky_failure_dismissal_enabled -- because it spends real
  # extra command runs on every Job whose diff touches spec files.
  # new_test_flakiness_gate_repeats overrides the default repeat count; nil
  # means use TouchedTestRepeatGate::DEFAULT_REPEATS.
  def up
    unless column_exists?(:repositories, :new_test_flakiness_gate_enabled)
      add_column :repositories, :new_test_flakiness_gate_enabled, :boolean, default: false, null: false
    end
    unless column_exists?(:repositories, :new_test_flakiness_gate_repeats)
      add_column :repositories, :new_test_flakiness_gate_repeats, :integer
    end
  end

  def down
    remove_column :repositories, :new_test_flakiness_gate_repeats if column_exists?(:repositories, :new_test_flakiness_gate_repeats)
    remove_column :repositories, :new_test_flakiness_gate_enabled if column_exists?(:repositories, :new_test_flakiness_gate_enabled)
  end
end
