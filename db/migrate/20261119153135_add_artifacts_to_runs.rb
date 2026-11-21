class AddArtifactsToRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :runs, :artifacts, :json unless column_exists?(:runs, :artifacts)
  end
end
