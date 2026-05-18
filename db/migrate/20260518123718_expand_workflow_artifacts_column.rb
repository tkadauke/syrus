class ExpandWorkflowArtifactsColumn < ActiveRecord::Migration[8.1]
  MEDIUMTEXT_LIMIT = 16.megabytes - 1

  def up
    change_column :workflows, :artifacts, :text, limit: MEDIUMTEXT_LIMIT
  end

  def down
    change_column :workflows, :artifacts, :text
  end
end
