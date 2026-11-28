class AddLaunchFailuresToCoworkerEnvironmentActivations < ActiveRecord::Migration[8.1]
  def up
    add_column :coworker_environment_activations, :launch_failure_count, :integer, default: 0, null: false unless column_exists?(:coworker_environment_activations, :launch_failure_count)
    add_column :coworker_environment_activations, :last_launch_failed_at, :datetime unless column_exists?(:coworker_environment_activations, :last_launch_failed_at)
  end

  def down
    remove_column :coworker_environment_activations, :last_launch_failed_at if column_exists?(:coworker_environment_activations, :last_launch_failed_at)
    remove_column :coworker_environment_activations, :launch_failure_count if column_exists?(:coworker_environment_activations, :launch_failure_count)
  end
end
