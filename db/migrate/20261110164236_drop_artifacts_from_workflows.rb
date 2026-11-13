class DropArtifactsFromWorkflows < ActiveRecord::Migration[8.1]
  def up
    remove_column :workflows, :artifacts if column_exists?(:workflows, :artifacts)
  end

  def down
    add_column :workflows, :artifacts, :text, limit: 16777215 unless column_exists?(:workflows, :artifacts)
  end
end
