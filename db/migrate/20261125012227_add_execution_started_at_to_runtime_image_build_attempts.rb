class AddExecutionStartedAtToRuntimeImageBuildAttempts < ActiveRecord::Migration[8.1]
  def change
    # Set once by the first job delivery that executes an attempt, so a
    # duplicate delivery of the same attempt cannot run the build twice.
    add_column :runtime_image_build_attempts, :execution_started_at, :datetime unless column_exists?(:runtime_image_build_attempts, :execution_started_at)
  end
end
